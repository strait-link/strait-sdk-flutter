# ADR 0001: opt-out switch `setEnabled(false)`

Date: 5 Nov 2026 · Status: accepted · Backlog: td2-27 · Same design in strait-sdk-react-native (ADR 0002), -web, -android, -swift

## Problem
Apps in India (DPDP Act) and the EU (GDPR) often have to ask a person for consent before an attribution SDK
sends anything. Without a switch they must not start Strait at all, which also loses the deferred link, or
they pick a rival SDK that has one (Branch documents `disableTracking`; Adjust documents an enabled switch).

## Who it serves
App teams with a consent screen: one call when the person says no, one when they say yes.

## Options
1. **Do nothing**: apps skip `start()` until consent. Loses direct-link routing and the install's deferred link.
2. **A config flag at create time only**: can't change after a consent answer without recreating the client.
3. **A persisted runtime switch** `setEnabled(bool)` + `isEnabled()`, default on. **Chosen.**

## Design
- Stored as `strait.enabled` (`'0'` / `'1'`) in the app's own storage; absent or unreadable = on (same rule as
  every other read; an unreadable store can't persist an opt-out anyway).
- Off: every engine call is refused in the one HTTP helper (belt), and each entry point returns early (braces):
  no `/v1/open`, `/v1/event`, `/v1/match`, `/v1/referrer`, `/v1/handoff/claim`, `/v1/resolve`, `/v1/store-sheet`,
  debug fingerprint. Nothing is queued and no tap id is remembered. Turning it off deletes the saved queue and
  the remembered tap (data collected for sending is not sent after the person said no).
- Links: a link that carries its own destination (App Link to your own domain, custom scheme) still reaches the
  link callback, unreported. A Strait short link needs `/v1/resolve`, which records the tap, so it returns
  `matched: false, reason: 'disabled'`; the app can open it in the browser if it wants.
- First launch while off: the once-per-install check is not marked done. `setEnabled(true)` in the same launch
  runs it then (the usual "consent screen on first launch" flow keeps its deferred link); otherwise the next
  start does.
- Flutter web: the same rules; a web build never has a first-launch check, so only routing and reports apply.
- `doctor()` (a setup check that reads the public AASA / assetlinks file) is not a report and still works.

## Security lens
Spoofing / tampering: none new (local flag in the app's sandbox). Data exposure: the point of the change;
accepted risk = a storage read that fails reads as "on". Abuse / DoS: none (fewer requests).

## Architecture lens
No engine or wire change. Follow-up E3 (engine): a lookup-only `/v1/resolve` (`record:false`) would let short
links route while opted out.

## Update 5 Nov 2026: short links route while off (follow-up E3)
The engine now has `POST /v1/lookup` (engine ADR 0083): the same workspace-scoped lookup as `/v1/resolve`,
recording nothing (no tap, no open, no counter, no webhook, no tap id; Strait's code writes no IP or user
agent, while Cloudflare and Render keep their usual short-lived request logs, as for every request). While
off, a Strait short link is looked up there with the publishable key and the link's host + path only (no
query string, not even utm_source): no openId, platform, device class or app state. The link callback gets `matched: true`
with the destination and no `clickId`; nothing is queued, remembered or retried. A failed lookup (offline,
429, or an engine without it: 404, so it fails closed) comes back `reason: 'disabled'` as before. This is
the one engine call allowed while off; it bypasses the opt-out gate by name, nothing else does.

## Update 5 Nov 2026: follow-ups F2 + F4 (`ops/run-1105/sdk-privacy-followups.md`)
- **F2, web.** A short link handed to `handleUrl` on the web called `/v1/resolve` without an openId so as
  "to record nothing", but the engine treats a resolve without an openId as an older SDK and records a tap
  (and fires `link.clicked`). The web now asks `/v1/lookup` (same body as the opted-out path), which is what
  the comment promised. Options weighed: send an openId (the engine would then record an app open: a web
  page is not an app open), or keep `/v1/resolve` and fix the comment (a short link handed in by page script
  is not a tap: the browser already recorded the real tap when it followed the link). No answer is
  `reason: 'network'` (the SDK is on).
- **F4, switch-off mid-call.** `setEnabled(false)` while `/v1/resolve` is out made that call fail at the
  gate and the link came back `reason: 'network'` with an open report queued for later (dropped by the
  queue's own gate). Now a failed resolve re-reads the switch and, when off, routes through `/v1/lookup`.
  A resolve reply that lands after the switch went off still routes (the engine already has it; that request
  left while on), but its tap id is no longer remembered.

## Update 5 Nov 2026: follow-up F5, the legacy `resolveDeferredLink`
The older one-call API had no storage and so never saw the switch: an opted-out app that still called it
posted `/v1/match`, which records an install. It now takes `storage` (the one passed to `StraitLinks`) and
returns `MatchResult.none` with no call while `strait.enabled` is `'0'` there. Unreadable storage counts as on,
as in `StraitLinks`. Without `storage` it can't read the switch (the `StraitLinks` default is in memory); the
README says to pass it. Same fix as React Native (its ADR 0002) and Swift.

## Update 5 Nov 2026: follow-up F7, the iPhone clipboard
Switched off while the first-launch check was out (after `/v1/match` answered with paste handoff on), the SDK
still read the clipboard, which shows iOS's paste prompt to a person who just said no; the claim itself was
already refused by the gate. The switch is now checked before the prompt-free detect and again between the
detect and the read (the read is what prompts). Found in the Unity port's review (`ops/run-1105/sdk-optout-2.md`).
The check then ends with the `/v1/match` answer (`no_match`) and is marked done: that request left while the SDK
was on and the engine already counted the install, so switching back on does not send a second match for the
same install (the paste step is not retried for it).
