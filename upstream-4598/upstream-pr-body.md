## Problem

Sidebar sparkline frames start a countdown when their request starts (`turbo:before-fetch-request`). If it expires, `turbo_frame_timeout_controller` replaces the frame with a "Timeout" badge. The countdown was cleared on `turbo:frame-load`.

Turbo inserts a frame's new content first and dispatches `turbo:frame-load` only a few repaints later (`FrameRenderer#render`: `nextRepaint` → `loadFrameElement` → two more `nextRepaint`s → event). If the countdown expires in that gap, the badge overwrites the chart that has just been drawn, and nothing replaces it again. The frame ends up `complete`, not `busy`, and shows "Timeout" for good although the request succeeded.

- In production (10 s window), a sparkline whose response arrives just before the 10 s mark can keep a false "Timeout" badge.
- In the system tests (300 ms window), this happens often enough to make `test/system/sidebar_sparklines_test.rb` flaky. This is the flakiness #4598 addresses by loosening the tests. With that approach, no test fails anymore if the countdown is never cleared.

I confirmed the cause by logging Turbo events and the controller in the browser during failing runs: the timeout fired after the response had been inserted and before `turbo:frame-load`.

## Change

- `AccountsHelper#sparkline_frame_data`: clears the countdown on `turbo:before-frame-render` instead of `turbo:frame-load`. Turbo dispatches it only when the response contains the matching frame, right before inserting it, so the countdown can no longer expire in the render gap.
- Responses without the frame never reach that event and keep counting, so they still end in the badge, as today: errors (404, 500) and the sign-in page a request is redirected to after the session expired (Turbo dispatches `turbo:frame-missing` there).
- `turbo_frame_timeout_controller.js`: header comment updated; no new method.
- Sidebar fragment cache version `account_sidebar_tabs_v5` → `v6`. The fragment is cached for 12 h with `skip_digest: true`, so cached markup would otherwise keep the old wiring.
- `test/system/sidebar_sparklines_test.rb`:
  - Badge checks first wait until no frame is `busy` (Turbo sets it only while a request is in flight), then wait out the window and check all frames, group totals included. A slow runner no longer fails them, while a countdown that is never cleared still does.
  - New: "a sparkline that has rendered is not replaced by the timeout badge". It slows the repaints Turbo waits for after inserting the response, so the window expires inside the gap, and it asserts that the responses arrived before the window. It fails deterministically on the old wiring.
  - New: "an error response still raises the timeout badge" (server answers 500) and "a response without the sparkline frame still raises the timeout badge" (server answers a page without the frame, like the sign-in page after a redirect). Both run with a 1.5 s window and assert that the response arrived inside it, so the badge proves the response did not clear the countdown.

## Validation

- `bin/rails test`: full suite green.
- `test/system/sidebar_sparklines_test.rb`: 20 consecutive runs green with the first version, 8 more with the `turbo:before-frame-render` wiring.
- Mutation checks:
  - Countdown never cleared → 3 tests fail.
  - Countdown started in `connect()` (the bug fixed in #3576) → 3 tests fail.
  - Every response clears the countdown → the error test and the missing-frame test fail.
  - Every successful response clears the countdown (`fetchResponse.succeeded`) → the missing-frame test fails.
  - Old `turbo:frame-load` wiring → the render-gap test fails (5/5 runs).
- Rubocop, erb_lint, `biome lint` and Brakeman are clean.

No screenshots: the visible effect is a timing race (a chart replaced by "Timeout" right after it renders). The system tests assert the drawn `svg path` and the absence of the badge instead.

Related: #4598 changes the same test file in a different direction, so the two PRs conflict.
