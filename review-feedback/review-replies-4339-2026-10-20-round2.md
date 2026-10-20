# Review reply for upstream PR 4339 (round 2, 2026-10-20)

Fix commit: f3f326a5d. Reply on the thread, then resolve it. Check first whether gfr-free already replied; if so, only resolve.

## PRRT_kwDOPRMXr86uShs6 (CodeRabbit, normalize separators in mask_identifier)

Good point, fixed in f3f326a5d. `mask_identifier` now passes `strip_whitespace: true, strip_dashes: true` for the whole value and for the account part before the "/", so an Akahu account shows `•••2300` in both the notes and Additional details, and a grouped IBAN masks to its last 4 characters. The test now expects `•••2300`, and a new test covers a grouped IBAN.
