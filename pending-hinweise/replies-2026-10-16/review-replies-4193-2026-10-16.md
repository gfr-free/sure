# Reply for upstream PR 4193, CodeRabbit outside-diff finding (review 2026-10-14 05:23, mobile_device.rb:27-32)

Post as a PR comment (the finding has no inline thread). First check whether gfr-free already answered it; if so, skip.

---

@coderabbitai Thanks, but I'd keep the exact `redirect_uri` match on purpose. Before this PR, dynamic client registration let anyone create a client named "Sure Mobile", and nothing stops such a client from listing `sureapp://oauth/callback` next to its own URI. If `shared_oauth_application` accepted any same-named app whose URIs merely include the callback, an older client like that could become the app the mobile flow uses, and Doorkeeper would then also accept its other redirect URI for authorization requests that show up as "Sure Mobile". Matching the whole value means the shared app can only ever redirect to the mobile callback. The trade-off is that an instance where an admin added a second URI to "Sure Mobile" by hand gets a separate app with just the callback; I think that is the safer default than trusting any same-named client.
