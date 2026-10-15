Reply to CodeRabbit (Major, app/models/transfer.rb, "Enforce cross-role uniqueness at the database boundary") on upstream PR 4216

Status: draft, not posted.

---

Thanks. I traced the paths and I'm keeping this at the model validation for now.

For the race to happen, two writes would have to commit at the same time, one using a transaction as an inflow and the other using it as an outflow. Every write path checks the sign first: `transfer_has_opposite_amounts` needs the inflow negative and the outflow positive, and the auto-matcher, the Trade Republic importer and the manual match all pick a transaction's role from its sign. So both writes can only pass if the transaction's sign is edited between them, during an overlapping sync or match. Same-role races, the ones the syncs actually produce, are already enforced by the two unique indexes.

`Transfer.insert!` skips validations, but the app never calls it. Only the index tests in this PR use it.

A database-level guard would mean either a transfer-leg table (a schema change across every reader of `inflow_transaction_id` and `outflow_transaction_id`) or a trigger with an advisory lock. Both are a lot of code for a sign-edit-plus-race that no caller produces, and the migration already cleans up any existing cross-role pairs. If maintainers want the trigger anyway, I'm happy to add it in a follow-up.
