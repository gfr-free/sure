## Problem

Sidebar sparkline frames start a countdown when their request starts (`turbo:before-fetch-request`). If it expires, `turbo_frame_timeout_controller` replaces the frame with a "Timeout" badge. The countdown was cleared on `turbo:frame-load`.

Turbo inserts a frame's new content first and dispatches `turbo:frame-load` only a few repaints later (`FrameRenderer#render`: `nextRepaint` → `loadFrameElement` → two more `nextRepaint`s → event). If the countdown expires in that gap, the badge overwrites the chart that has just been drawn, and nothing replaces it again. The frame ends up `complete`, not `busy`, and shows "Timeout" for good although the request succeeded.

- In production (10 s window), a sparkline whose response arrives just before the 10 s mark can keep a false "Timeout" badge.
- In the system tests (300 ms window), this happens often enough to make `test/system/sidebar_sparklines_test.rb` flaky. This is the flakiness #4598 addresses by loosening the tests. With that approach, no test fails anymore if the countdown is never cleared.

I confirmed the cause by logging Turbo events and the controller in the browser during failing runs: the timeout fired after the response had been inserted and before `turbo:frame-load`.

## Change

- `turbo_frame_timeout_controller.js`: new `responseReceived(event)` clears the countdown when a successful response arrives (`event.detail.fetchResponse.succeeded`). Error responses (404, 500, login redirect) keep counting, so they still end in the badge, as today.
- `AccountsHelper#sparkline_frame_data`: wires `turbo:before-fetch-response->turbo-frame-timeout#responseReceived` instead of `turbo:frame-load->turbo-frame-timeout#clearTimeout`.
- Sidebar fragment cache version `account_sidebar_tabs_v5` → `v6`. The fragment is cached for 12 h with `skip_digest: true`, so cached markup would otherwise keep the old wiring.
- `test/system/sidebar_sparklines_test.rb`:
  - Badge checks first wait until no frame is `busy` (Turbo sets it only while a request is in flight), then wait out the window and check all frames, group totals included. A slow runner no longer fails them, while a countdown that is never cleared still does.
  - New: "a sparkline that has rendered is not replaced by the timeout badge". It slows the repaints Turbo waits for after inserting the response, so the window expires inside the gap, and it asserts that the responses arrived before the window. It fails deterministically on the old wiring.
  - New: "an error response still raises the timeout badge" (server answers 500).

## Validation

- `bin/rails test`: full suite green.
- `test/system/sidebar_sparklines_test.rb`: 20 consecutive runs green.
- Mutation checks:
  - Countdown never cleared → 2 tests fail.
  - Countdown started in `connect()` (the bug fixed in #3576) → 3 tests fail.
  - Every response clears the countdown → the error test fails.
  - Old `turbo:frame-load` wiring → the render-gap test fails (5/5 runs).
- Rubocop, erb_lint, `biome lint` and Brakeman are clean.

No screenshots: the visible effect is a timing race (a chart replaced by "Timeout" right after it renders). The system tests assert the drawn `svg path` and the absence of the badge instead.

Related: #4598 changes the same test file in a different direction, so the two PRs conflict.
