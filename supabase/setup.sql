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
