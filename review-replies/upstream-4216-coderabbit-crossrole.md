Reply to CodeRabbit (Major, app/models/transfer.rb, "Enforce cross-role uniqueness at the database boundary") on upstream PR 4216

Status: draft, not posted. Fix commit d98cd7b62.

---

Thanks. Addressed in d98cd7b62 by closing the race; I'm not adding a database-level constraint.

The cross-role validation now takes a transaction-scoped advisory lock (`pg_advisory_xact_lock`) on each leg before it checks the transfers table. The lock is held until the save transaction commits. A concurrent save that uses the same transaction in the other role waits on that lock and then sees the committed transfer, so it fails the validation instead of inserting a duplicate. Locks are taken in sorted order. The same-role case is still enforced by the two unique indexes.

Test: `TransferTest` checks from a second database connection that both legs are locked while the validating transaction is open. It fails without the lock.

I did not add a trigger or a transfer-leg table:
- A trigger can't be represented in `db/schema.rb`, so the test database wouldn't have it without switching the project to `structure.sql`.
- A leg table would be a data-model change across every reader of `inflow_transaction_id` and `outflow_transaction_id`.

`Transfer.insert!` still bypasses the check. The app never calls it; only the index tests in this PR do.
