# Note for upstream PR 4205 (no reply needed unless asked)

Commit 5c37f07 on claude/project-thread-01v0je (pushed 2026-10-16): `family_export_attachment_authorized?` now also rescues NoMethodError, mirroring d24895a on PR 4203 after jjmata's nit there. Keeps the method identical in both PRs. Note: 4203 and 4205 still conflict with each other in config/initializers/active_storage_authorization.rb (PROTECTED_RECORD_TYPES and the case statement); whichever merges second needs a merge of main. This was already the case before this commit.
