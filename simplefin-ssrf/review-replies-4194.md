# Replies for upstream PR 4194 (commit 89443f66e)

Read each comment first; post only where the reply matches the ask, then resolve the thread.

## discussion_r4265452145 (Codex, proxy pinning)
Fixed in 89443f66e. HTTPS through a proxy was already pinned, because Net::HTTP sends CONNECT to the pinned address. Plain http requests (self-hosted only) now skip the proxy and connect to the checked address directly. Tests added.

## discussion_r4265452150 (Codex, Alibaba metadata)
Fixed in 89443f66e: 100.100.100.200 is now blocked in every mode, not only via the managed CGNAT rule. Test added.

## discussion_r4265452154 (Codex, IPv4-mapped IPv6)
Fixed in 89443f66e: IPv4-mapped addresses are checked as their IPv4 address and the connection is pinned to the plain IPv4 form. Test added.

## discussion_r4265452158 (Codex, DNS fallback)
Fixed in 89443f66e: the check keeps all allowed addresses (IPv4 first) and each retry connects to the next one, so a dead first address no longer fails the whole request. Test added.

## discussion_r4265452166 (Codex, reconnect job reporting)
Fixed in 89443f66e: when the reconnect job is discarded on a SimpleFIN error, it now writes a debug log entry with the item id and error type (no token). Combined with the synchronous check in the update action, a rejected token is also shown to the user right away. Test added.

## discussion_r4265785458 (jjmata, update never validates synchronously)
Good catch, fixed in 89443f66e. The update action now runs the same claim-URL check (scheme and resolved addresses) before queueing the reconnect job, so a disallowed or malformed token gets the "Invalid setup token" error immediately and no job is queued. Test added.

## r4265452154 (Codex, IPv4-translated) — updated reply, post after CI is green on 1921df471

Good catch — the earlier change only covered IPv4-mapped addresses (`::ffff:a.b.c.d`). IPv4-translated addresses in `::ffff:0:0:0/96` (e.g. `::ffff:0:169.254.169.254`) are now unwrapped like NAT64 and checked as their embedded IPv4 address, with a test case added. Fixed in 1921df471.
