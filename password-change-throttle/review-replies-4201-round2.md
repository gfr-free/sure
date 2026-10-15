# Upstream PR 4201: review replies round 2 (fix pushed in 812563b)

## r4279137124 (CodeRabbit, rack_attack.rb:157, sessions of deactivated users)

Good catch, fixed in 812563b. The throttle lookup now uses the same condition as `Authentication#find_session_by_cookie` (`Session.joins(:user).where(id:, users: { active: true })`), so a session whose owner was deactivated (and is only cleaned up later) produces neither a user key nor an IP key. New test `password change throttles ignore a session whose user was deactivated`, which fails without the fix.
