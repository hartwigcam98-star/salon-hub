-- =====================================================================
-- Salon Hub database setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run again later (it only adds what's missing / refreshes rules).
--
-- Access model
--   • Only people listed in "members" can see or change anything.
--   • The first person to sign in becomes the owner automatically.
--   • owner / manager: everything. staff: clients, calendar, menu,
--     and their OWN private staff details only.
--   • Pay, employment, emergency contact and onboarding details live in
--     staff_private, which other stylists cannot read.
-- =====================================================================

set client_min_messages = warning;

create table if not exists public.members (
  email      text primary key,
  role       text not null default 'staff' check (role in ('owner','manager','staff')),
  staff_id   text,
  created_at timestamptz not null default now()
);

-- ---------- helper functions ----------
create or replace function public.my_email() returns text
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where lower(email) = public.my_email()
$$;

create or replace function public.my_staff_id() returns text
language sql stable security definer set search_path = public as $$
  select staff_id from public.members where lower(email) = public.my_email()
$$;

create or replace function public.is_member() returns boolean
language sql stable as $$ select public.my_role() is not null $$;

create or replace function public.is_manager() returns boolean
language sql stable as $$ select coalesce(public.my_role() in ('owner','manager'), false) $$;

create or replace function public.is_owner() returns boolean
language sql stable as $$ select coalesce(public.my_role() = 'owner', false) $$;

-- First signed-in user becomes owner; afterwards this does nothing.
create or replace function public.claim_owner() returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.my_email() = '' then return null; end if;
  if not exists (select 1 from public.members where role = 'owner') then
    insert into public.members (email, role) values (public.my_email(), 'owner')
    on conflict (email) do update set role = 'owner';
  end if;
  return public.my_role();
end $$;

create or replace function public.my_access() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('role', role, 'staff_id', staff_id)
  from public.members where lower(email) = public.my_email()
$$;

create or replace function public.touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := public.my_email();
  return new;
end $$;

-- ---------- data tables (one JSON record per row) ----------
do $$
declare t text;
begin
  foreach t in array array['clients','staff','staff_private','services','appointments',
                           'products','giftcards','packages','memberships','settings'] loop
    execute format('create table if not exists public.%I (
        id         text primary key,
        data       jsonb not null default ''{}''::jsonb,
        updated_at timestamptz not null default now(),
        updated_by text default public.my_email()
      )', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('drop trigger if exists touch on public.%I', t);
    execute format('create trigger touch before update on public.%I for each row execute function public.touch()', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists "team can read" on public.%I', t);
    execute format('drop policy if exists "team can write" on public.%I', t);
    execute format('drop policy if exists "managers can write" on public.%I', t);
    execute format('drop policy if exists "own record" on public.%I', t);
  end loop;

  -- Everyone on the team can read and update these
  foreach t in array array['clients','appointments','products','giftcards'] loop
    execute format('create policy "team can read" on public.%I for select to authenticated using (public.is_member())', t);
    execute format('create policy "team can write" on public.%I for all to authenticated using (public.is_member()) with check (public.is_member())', t);
  end loop;

  -- Everyone can read; only owner/managers can change
  foreach t in array array['staff','services','packages','memberships','settings'] loop
    execute format('create policy "team can read" on public.%I for select to authenticated using (public.is_member())', t);
    execute format('create policy "managers can write" on public.%I for all to authenticated using (public.is_manager()) with check (public.is_manager())', t);
  end loop;
end $$;

-- Private staff details: owner/managers, plus each person can read their own
create policy "managers can write" on public.staff_private for all to authenticated
  using (public.is_manager()) with check (public.is_manager());
create policy "own record" on public.staff_private for select to authenticated
  using (id = public.my_staff_id());

-- ---------- team list ----------
alter table public.members enable row level security;
revoke all on public.members from anon;
grant select, insert, update, delete on public.members to authenticated;
drop policy if exists "see team" on public.members;
drop policy if exists "owner manages team" on public.members;
create policy "see team" on public.members for select to authenticated
  using (public.is_manager() or lower(email) = public.my_email());
create policy "owner manages team" on public.members for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

revoke execute on function public.claim_owner() from anon;
revoke execute on function public.my_access() from anon;
grant execute on function public.claim_owner(), public.my_access(), public.my_email(),
  public.my_role(), public.my_staff_id(), public.is_member(), public.is_manager(), public.is_owner()
  to authenticated;

-- =====================================================================
-- ONLINE BOOKING (public booking page)
-- The public can't read any table directly. These three functions expose
-- only what the booking page needs, and book_appointment re-checks every
-- rule on the server so a booking can't be forced into a taken slot.
-- =====================================================================

-- Opening hours for one day from a weekly_hours object; app defaults: open Mon–Sat 9–5.
create or replace function public.day_hours(wh jsonb, d date, out open_at time, out close_at time)
language plpgsql immutable as $$
declare k text := lower(to_char(d, 'dy')); x jsonb := coalesce(wh -> k, '{}'::jsonb);
begin
  if coalesce((x ->> 'on')::boolean, k <> 'sun') then
    open_at  := coalesce(nullif(x ->> 'start', ''), '09:00')::time;
    close_at := coalesce(nullif(x ->> 'end', ''), '17:00')::time;
  end if;
end $$;

create or replace function public.booking_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'settings', (select jsonb_build_object(
        'salon_name', d->'salon_name', 'phone', d->'phone', 'email', d->'email', 'address', d->'address',
        'city', d->'city', 'state', d->'state', 'zip', d->'zip', 'timezone', d->'timezone',
        'website', d->'website', 'instagram', d->'instagram',
        'business_hours', d->'business_hours', 'closures', d->'closures',
        'slot_interval', d->'slot_interval', 'buffer_min', d->'buffer_min',
        'min_notice_hours', d->'min_notice_hours', 'max_days_ahead', d->'max_days_ahead',
        'online_booking', d->'online_booking', 'new_clients_online', d->'new_clients_online',
        'deposit_required', d->'deposit_required', 'deposit_type', d->'deposit_type', 'deposit_amount', d->'deposit_amount',
        'cancel_window_hours', d->'cancel_window_hours', 'late_cancel_fee', d->'late_cancel_fee',
        'late_cancel_fee_type', d->'late_cancel_fee_type', 'no_show_fee', d->'no_show_fee',
        'no_show_fee_type', d->'no_show_fee_type', 'policy_text', d->'policy_text')
      from (select data d from settings where id = 'main') s),
    'services', coalesce((select json_agg(jsonb_build_object(
        'id', id, 'name', data->'name', 'category', data->'category', 'duration_min', data->'duration_min',
        'price', data->'price', 'price_from', data->'price_from', 'description', data->'description'))
      from services
      where coalesce((data->>'active')::boolean, true) and coalesce((data->>'book_online')::boolean, true)), '[]'),
    'staff', coalesce((select json_agg(jsonb_build_object(
        'id', id,
        'name', coalesce(nullif(data->>'display_name', ''),
                trim(coalesce(data->>'first_name', '') || ' ' || coalesce(left(nullif(data->>'last_name', ''), 1) || '.', ''))),
        'level', data->'level', 'bio', data->'bio', 'specialties', data->'specialties',
        'photo_url', data->'photo_url', 'instagram', data->'instagram', 'color', data->'calendar_color',
        'services_offered', coalesce(data->'services_offered', '[]'), 'weekly_hours', data->'weekly_hours',
        'time_off', (select coalesce(jsonb_agg(jsonb_build_object('start', t->'start', 'end', t->'end')), '[]')
                     from jsonb_array_elements(coalesce(data->'time_off', '[]')) t)))
      from staff
      where coalesce((data->>'active')::boolean, true) and coalesce((data->>'bookable_online')::boolean, true)), '[]')
  )
$$;

-- Taken time ranges only (no client names), for a window of up to 62 days.
create or replace function public.busy_times(p_from date, p_to date) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('staff_id', data->>'staff_id', 'date', data->>'date',
           'start', data->>'start_time', 'end', data->>'end_time')), '[]')
  from appointments
  where data->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
    and (data->>'date')::date between p_from and least(p_to, p_from + 62)
    and coalesce(data->>'status', '') not in ('Cancelled', 'No-show')
    and data->>'start_time' ~ '^\d{1,2}:\d{2}' and data->>'end_time' ~ '^\d{1,2}:\d{2}'
$$;

create or replace function public.book_appointment(p jsonb) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  s jsonb; st jsonb; svc jsonb; off jsonb;
  v_staff text := p->>'staff_id';
  v_date date; v_start time; v_end time; v_now timestamp;
  v_dur int := 0; v_total numeric := 0; v_lines jsonb := '[]'::jsonb;
  v_phone text := right(regexp_replace(coalesce(p->>'phone', ''), '\D', '', 'g'), 10);
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_first text := trim(coalesce(p->>'first_name', ''));
  v_client text; v_id text := gen_random_uuid()::text; v_buf int;
  h record; sid text; v_price numeric; v_min int;
begin
  select data into s from settings where id = 'main';
  if s is null or not coalesce((s->>'online_booking')::boolean, false) then
    raise exception 'Online booking is not available right now. Please call the salon.';
  end if;
  if v_first = '' then raise exception 'Please enter your first name.'; end if;
  if length(v_phone) < 10 then raise exception 'Please enter a valid mobile number.'; end if;
  begin
    v_date := (p->>'date')::date; v_start := (p->>'start_time')::time;
  exception when others then raise exception 'Please pick a date and time.'; end;

  select data into st from staff where id = v_staff
    and coalesce((data->>'active')::boolean, true) and coalesce((data->>'bookable_online')::boolean, true);
  if st is null then raise exception 'That stylist isn''t available for online booking.'; end if;

  -- Services: must exist, be bookable, and be offered by this stylist. Price/time use stylist overrides.
  if jsonb_typeof(p->'service_ids') <> 'array' or jsonb_array_length(p->'service_ids') = 0 then
    raise exception 'Please choose a service.';
  end if;
  for sid in select jsonb_array_elements_text(p->'service_ids') loop
    select data into svc from services where id = sid
      and coalesce((data->>'active')::boolean, true) and coalesce((data->>'book_online')::boolean, true);
    select o into off from jsonb_array_elements(coalesce(st->'services_offered', '[]')) o where o->>'service_id' = sid;
    if svc is null or off is null then raise exception 'That service isn''t available with this stylist.'; end if;
    v_price := coalesce(nullif(off->>'price', '')::numeric, nullif(svc->>'price', '')::numeric, 0);
    v_min   := coalesce(nullif(off->>'duration_min', '')::numeric, nullif(svc->>'duration_min', '')::numeric, 30)::int;
    v_lines := v_lines || jsonb_build_object('service_id', sid, 'price', v_price, 'duration_min', v_min);
    v_total := v_total + v_price; v_dur := v_dur + v_min;
  end loop;
  if v_start + make_interval(mins => v_dur) < v_start then raise exception 'That time runs past midnight.'; end if;
  v_end := v_start + make_interval(mins => v_dur);

  -- Booking window
  v_now := now() at time zone coalesce(nullif(s->>'timezone', ''), 'America/Chicago');
  if v_date + v_start < v_now + make_interval(hours => coalesce(nullif(s->>'min_notice_hours', '')::int, 2)) then
    raise exception 'That time is too soon to book online. Please pick a later time or call us.';
  end if;
  if v_date > v_now::date + coalesce(nullif(s->>'max_days_ahead', '')::int, 90) then
    raise exception 'That date is too far ahead to book online.';
  end if;

  -- Salon open, stylist working, not a closure or time off
  if exists (select 1 from jsonb_array_elements(coalesce(s->'closures', '[]')) c where c->>'date' = v_date::text) then
    raise exception 'The salon is closed that day.';
  end if;
  select * into h from public.day_hours(s->'business_hours', v_date);
  if h.open_at is null or v_start < h.open_at or v_end > h.close_at then raise exception 'That time is outside salon hours.'; end if;
  select * into h from public.day_hours(st->'weekly_hours', v_date);
  if h.open_at is null or v_start < h.open_at or v_end > h.close_at then raise exception 'Your stylist isn''t working at that time.'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(st->'time_off', '[]')) t
             where nullif(t->>'start', '') is not null
               and v_date between (t->>'start')::date and coalesce(nullif(t->>'end', ''), t->>'start')::date) then
    raise exception 'Your stylist is away that day.';
  end if;

  -- No double booking (lock this stylist+day while we check and insert)
  perform pg_advisory_xact_lock(hashtext(v_staff || v_date::text));
  v_buf := coalesce(nullif(s->>'buffer_min', '')::int, 0);
  if exists (select 1 from appointments a
             where a.data->>'staff_id' = v_staff and a.data->>'date' = v_date::text
               and coalesce(a.data->>'status', '') not in ('Cancelled', 'No-show')
               and a.data->>'start_time' ~ '^\d{1,2}:\d{2}' and a.data->>'end_time' ~ '^\d{1,2}:\d{2}'
               and (a.data->>'start_time')::time < v_end + make_interval(mins => v_buf)
               and (a.data->>'end_time')::time + make_interval(mins => v_buf) > v_start) then
    raise exception 'Sorry, that time was just taken. Please pick another.';
  end if;

  -- Find the client by phone (then email), or create them
  select id into v_client from clients
   where right(regexp_replace(coalesce(data->>'phone', ''), '\D', '', 'g'), 10) = v_phone limit 1;
  if v_client is null and v_email <> '' then
    select id into v_client from clients where lower(data->>'email') = v_email limit 1;
  end if;
  if v_client is null then
    if not coalesce((s->>'new_clients_online')::boolean, true) then
      raise exception 'Online booking is for existing clients. Please call the salon to book your first visit.';
    end if;
    v_client := gen_random_uuid()::text;
    insert into clients (id, data, updated_by) values (v_client, jsonb_build_object(
      'id', v_client, 'first_name', v_first, 'last_name', trim(coalesce(p->>'last_name', '')),
      'phone', p->>'phone', 'email', v_email, 'sms_opt_in', coalesce((p->>'sms_opt_in')::boolean, false),
      'notes', 'Created by online booking.', 'created_at', now(), 'updated_at', now()), 'online booking');
  end if;

  -- Simple abuse guard: at most 4 upcoming online bookings per client
  if (select count(*) from appointments where data->>'client_id' = v_client and data->>'booked_via' = 'Online'
        and data->>'status' = 'Booked' and data->>'date' >= v_now::date::text) >= 4 then
    raise exception 'You already have several upcoming bookings. Please call the salon to book more.';
  end if;

  insert into appointments (id, data, updated_by) values (v_id, jsonb_build_object(
    'id', v_id, 'date', v_date, 'start_time', to_char(v_start, 'HH24:MI'), 'end_time', to_char(v_end, 'HH24:MI'),
    'duration_min', v_dur, 'client_id', v_client, 'staff_id', v_staff, 'services', v_lines,
    'total_price', v_total, 'status', 'Booked', 'booked_via', 'Online', 'deposit_paid', '',
    'notes', left(trim(coalesce(p->>'notes', '')), 500), 'external_id', '',
    'created_at', now(), 'updated_at', now()), 'online booking');

  return json_build_object('id', v_id, 'date', v_date, 'start_time', to_char(v_start, 'HH24:MI'),
    'end_time', to_char(v_end, 'HH24:MI'), 'total_price', v_total, 'duration_min', v_dur);
end $$;

grant execute on function public.booking_info(), public.busy_times(date, date), public.book_appointment(jsonb) to anon, authenticated;
