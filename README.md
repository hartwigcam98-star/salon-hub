# Salon Hub

Our own salon management system, which will fully replace the third-party booking platform.

## What's built
- **Calendar**: day view of appointments for all stylists or one stylist, with who's working, time off, and closed days. Book, edit, check in, complete, cancel or mark no-show.
- **Clients**: contact info, preferred stylist, allergies, color formulas, notes, membership, opt-ins, and visit history (lifetime spend, last visit).
- **Staff**: full stylist profile with booking bio, services and per-stylist pricing, weekly hours, time off, pay structure, employment and reviews, license and certifications (expiry alerts), emergency contact, and onboarding checklist.
- **Services**: menu with category, duration, price and processing time.
- **More**: retail products (stock and reorder alerts), gift cards (codes and balances), packages, membership plans, salon settings (hours, closures, booking rules, deposits, cancellation and no-show policy, tax, tips), and data tools.
- **Data**: CSV import from the old platform for clients, staff, services, appointment history, products and gift cards; JSON backup and restore; CSV export.

## Where data lives
This repo is public, so **no customer or employee data is ever committed here**.
For now, records are saved in the browser's localStorage. All storage goes through the
`DB` object in `index.html`. The next step replaces it with a hosted database and staff logins.

Payroll and tax details (SSNs, bank accounts) are kept with the payroll provider and are never entered here.

## Roadmap
1. ✅ Records: clients, staff, services, products, gift cards, packages, memberships, settings
2. ✅ Appointment calendar and visit history
3. Hosted database and staff logins
4. Online booking page for clients, plus text reminders
5. Checkout through Stripe or Square, and commission reports exported to payroll
6. Import full history, run alongside the old platform, then switch over
