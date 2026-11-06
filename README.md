# Salon Hub

Our own salon management system, which will eventually replace the third-party booking platform.

## Phase 1 (current): the basic records
- **Clients**: contact info, preferred stylist, allergies, color formulas, notes, text/email opt-ins, and the client's ID in the old system
- **Staff (full stylist profile)**: profile and level, online booking bio, services with per-stylist pricing, weekly hours and time off, pay structure, employment and reviews, license and certifications (with expiry alerts), emergency contact, and an onboarding checklist
- **Services**: category, duration, price, processing time
- **Data**: CSV import from the current platform (columns matched automatically, duplicates skipped), JSON backup and restore, and CSV export

## Where data lives
This repo is public, so **no customer or employee data is ever committed here**.
Records are saved in the browser's localStorage on the device you use. Download a
backup from the Data tab regularly.

All storage goes through the `DB` object in `index.html`. Phase 2 will replace it with a
hosted database that has logins, so the whole team shares the same data. The rest of
the app won't need to change.

Payroll and tax details (SSNs, bank accounts) are kept with the payroll provider and are never entered here.

## Roadmap
1. ✅ Client, staff and service records
2. Hosted database and staff logins
3. Appointment calendar and stylist schedules
4. Online booking page for clients, plus text reminders
5. Checkout through Stripe or Square, and commission reports exported to payroll
6. Run alongside the old platform, then switch over
