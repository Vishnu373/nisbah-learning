# Future Considerations

- **Migration concurrency guard** — if the app is ever horizontally scaled (multiple backend instances running `migrate.ts` on boot simultaneously), add `select pg_advisory_lock(<id>)` before the migration loop so only one runner applies pending migrations at a time. Not needed on the current single-VPS setup with manual `db:migrate`.
- **Account deletion = anonymize, not hard-delete** — no deletion flow exists yet. When added, blank PII (name, email, photo) on the `users` row but retain contracts/payments/sessions for tax, dispute, and counterparty (payout) records. FKs currently RESTRICT deletes, which enforces this.
