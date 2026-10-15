## r4268702326 (app/controllers/accountable_sparklines_controller.rb, share-scoped cache key needs a monotonic generation)

Good catch, fixed in 4ec92a1. `Current.account_share_version` (share count plus newest `updated_at`) can stay the same while the accessible set changes. Two paths reproduce it: `User#reassign_owned_accounts!` moves ownership with `update_all(owner_id:)`, which touches neither a share nor an account timestamp; and a share that is replaced by one carrying an older timestamp (for example an `insert_all` with a timestamp taken earlier) keeps both the count and the maximum.

Instead of adding a generation column, the key now carries a SHA-256 digest of exactly the account rows the series is built from (id plus provider link ids, the same pluck `build_series` already uses). That digest changes whenever the accessible set changes, through shares or ownership, and can't repeat for a different set. The pluck is reused on a cache miss, so a hit or 304 costs one query instead of the previous two (count and max). The user id is no longer part of the key, because two users with the same accessible set get the same series.

Tests: `test_group_sparkline_cache_is_invalidated_when_account_ownership_moves_without_a_share_change` and `test_group_sparkline_cache_is_invalidated_when_a_share_is_replaced_without_a_newer_timestamp`. Both fail without the fix.
