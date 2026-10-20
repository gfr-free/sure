# PR comment for upstream PR 4339 (round 3, 2026-10-20)

Post as one PR comment (gh pr comment 4339 --repo we-promise/sure --body-file ...), since both findings are outside-diff notes in the CodeRabbit review body and have no thread. Check first that gfr-free has not already posted it.

---

@coderabbitai Thanks for the two outside-diff notes in the last review.

**Account names that carry the full number elsewhere** (`mask_account_numbers_in_generated_account_names.rb`): agreed, fixed in 6bcca33da. The cleanup now replaces the exact full number wherever it appears in a provider record's or linked account's name, not only as the generated suffix, so "TFSA 12345678 (old)" becomes "TFSA •••5678 (old)". Wording around the number is still kept, and the Interactive Brokers record named after the bare id still gets the default name. New test added.

**Several trailing hashes in Mercury notes** (`remove_mercury_routing_details_from_notes.rb`): I'm leaving this as is. The old processor wrote `[note, details].join(" - ")`, so a stored note has at most one details hash and it is always last. The pattern only starts at ` - {` followed by one of Mercury's details keys and is anchored at the end. Your example `Rent - {"counter_account"=>"123"} - {"custom"=>"keep"}` does not match at all, because neither hash starts with a details key, so the note stays unchanged (I checked this against the current pattern). The suggested `[^}]*` would also stop matching the real nested hashes such as `{"electronicRoutingInfo"=>{...}}`, which are the ones this migration has to remove.
