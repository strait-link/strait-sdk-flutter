# Changelog

## 0.9.5

- Flutter web: a web build has no install, so `StraitLinks.start()` no longer runs the
  once-per-install deferred check there (0.9.4 sent `/v1/match` on every first visit, which the
  engine recorded as an install), and an open from the page URL is never reported as a first
  launch. A link in the page URL still opens, is reported and attributes events. Detected at
  compile time (`dart.library.js_interop`, the same test as Flutter's `kIsWeb`); apps change nothing.
  `checkDeferred()` still asks when called.
- README: the `StraitLinks` example uses `kIsWeb` / `defaultTargetPlatform` instead of
  `dart:io`'s `Platform`, which throws on the web.
- CI runs the whole suite in Chrome too (dart2js and dart2wasm); the shared vectors load there
  through `test/support/fixture.dart`. Install-path tests are VM only.

## 0.9.4

- New: `links.doctor({appId, certSha256})`, a setup check for debug builds (contract B23, shared-spec
  ADR 0002). One GET of your link domain's `/.well-known/assetlinks.json` (Android) or
  `/.well-known/apple-app-site-association` (iOS), then checks the key (secret key in the app?), the
  endpoint, whether the file lists your app and (Android, when you pass it) this build's signing
  certificate. Never throws; prints each finding with `[Strait doctor]` only when asserts are on
  (debug builds); returns a `DoctorReport` (`ok`, `findings`). The same finding ids and wording as
  every Strait SDK. Also exported: the pure `doctorFindings(...)` and `DoctorFinding` / `DoctorReport`
  / `DoctorFile`. Pure Dart can't read the package or bundle ID, so pass `appId` (e.g. from
  `package_info_plus`; left out: `app.unknown`). No new dependency, no other behaviour change.

## 0.9.3

- New optional `deviceClass` callback on `StraitLinks` (contract B14, engine ADR 0039): `'phone'` or
  `'tablet'` is sent with `/v1/resolve`, `/v1/open` (queued retries too) and `/v1/store-sheet`.
  New `deviceClassForSize(shortestSide)`: >= 600 logical px = tablet. The README shows the Flutter
  wiring. Left out when not supplied; older engines ignore it. Conformance vectors v9.
- Docs: iPhone links are live, iPhone install matching is opt-in (off until you choose it) and the
  store sheet is new, in the README and the doc comments (no "beta" for iPhone). No behaviour change.

## 0.9.2

- Fix: a link that opens the app while the first-launch deferred check is still running is no
  longer followed by that check's *match* either (0.9.1 held back only its "no link" event). The
  app stays on the screen the person just tapped instead of jumping to a stale pre-install
  destination. The engine still counts the install and records and attributes the match as before,
  the check is still marked done, and the match is not added to `events` (no replay to late
  `onLink` listeners). `checkDeferred()` still returns (and delivers) its answer (contract B6).
- iPhone paste handoff: once a link has opened the app in this launch, the first-launch check no
  longer reads the clipboard, so iOS shows no "Allow Paste" prompt for an answer that won't be
  delivered. Checked again right after the prompt-free URL detect; a clipboard already read is
  claimed as before (contract B6/B19).
- Known gap (no API change): if the check had already sent its `onLinkStart` when the link arrived,
  no `onLink` event with that start's `id` follows. The documented pattern (loading on at any
  `onLinkStart`, off at any `onLink`) stays correct because the link's own start and event come
  after it; an app that tracks loading per `id` should also clear pending deferred ids when a
  `direct` event arrives.

## 0.9.1

- Fix: a link that opens the app while the first-launch deferred check is still running is no
  longer followed by that check's "no link" event (`matched: false`, `no_match` or `network`).
  Found with the React Native SDK on an Android emulator (13 Oct): the link was delivered
  (`/product/42`) and the check's `false` came right after it, so an app that routes home on
  `!matched` left the right screen. Flutter had the same race (`start(urls: ...)` listens for links
  before the check finishes). The check still runs and counts the install, and is marked done (or
  retried next launch) as before; only its no-link event is not delivered, and it sends no
  `onLinkStart` once a link is here (a loading state would never end). A deferred match is
  still delivered; `checkDeferred()` is unchanged (contract B6).

## 0.9.0

- Smaller public API (SDK-23, decision record: shared-spec `docs/adr/0001-sdk-public-api-surface.md`). `package:strait_sdk/strait_sdk.dart`
  no longer exports the contract helpers in `src/core.dart` (`classifyUrl`, `splitUrl`, `pruneOpenQueue`,
  `rememberTap`, `shouldRetryReport`, `newOpenId`, `parseStraitLink`, `pasteHandoffOn`, `AppStateTracker`,
  the queue and window constants, ...). They were never in the docs. Still public from core:
  `portraitScreenWidth`, `AppLifecycle`, `AppStateAtLink` and `LinkRoute`. Nothing else changed:
  `StraitLinks`, `resolveDeferredLink`, `DeviceFields`, `MatchResult` and the store sheet are as before.
  If you called one of the helpers anyway, import `package:strait_sdk/src/core.dart` (not a supported API).
- Migration: if you copied the dashboard's Flutter setup before 13 Oct, it called `browserScreenWidth(w)`.
  Use `portraitScreenWidth(w, h)` (what the docs and the dashboard show now). It is also the correct
  width when the app starts in landscape (contract B17).
- `example/example.dart` shows only `resolveDeferredLink`.

## 0.8.3

- `checkDeferred()` (the debug / settings re-check) now sends `"record": false` on `/v1/match` and `/v1/referrer`, so the
  engine answers the match without adding an install, an open or an `install.matched` webhook
  (contract B6: it never adds an install). The once-per-install check is unchanged. Takes effect
  once the engine with `record` support is live; an older engine ignores the field.
- Every request to the engine now gives up after 10 s (like the Android SDK's timeouts) and takes
  the existing `network` path: the deferred check is retried next launch and open reports stay
  queued. Before, a reply that never came hung `start()` and the open-report queue.

## 0.8.2

- First version on pub.dev. `v0.8.1` is a GitHub tag only and was never uploaded, so pub.dev
  starts at 0.8.2. Install lines written as `strait_sdk: ^0.8.1` resolve to it.
- Package metadata for pub.dev: homepage, repository, issue tracker, topics, and a runnable
  `example/example.dart`. The release workflow pins its actions by commit SHA.
- README: the common Strait SDK header (logo, the promise "Straight to the screen. On the record.",
  badges, links to docs, platform status and the changelog), a platform features table in the
  availability words (Live / Beta / Planned / Not yet) with the iPhone beta truth (the method is
  the customer's choice, device matching off by default), and a "Docs and support" section
  (Talk to the Strait team). The same structure in all seven SDK READMEs (design system v5).
- `example/example.dart` uses the sample Hilltop Shoes link host instead of `go.yourbrand.com`.
- iPhone deferred method is the customer's choice, at runtime (founder decision 10 Oct 2026):
  the SDK tries the paste handoff only when the engine's `/v1/match` reply has no match and
  says `ios.pasteHandoff: true` (Dashboard → Settings → iPhone installs). Nothing is stored or
  baked into the build, so a dashboard change needs no app release. No answer from the engine
  = the clipboard stays untouched (`network`, retried next launch). An older engine without
  the `ios` field = off. New `pasteHandoffOn(reply)` helper. `clipboardBoost` is deprecated
  and ignored. Tests cover off/off, device only, paste only and both. New workspaces start
  with device matching off.
- Clipboard boost order (B19): the first-launch iPhone check now runs device matching
  (`/v1/match`) first and reads the clipboard / claims the handoff only when it returns no
  match or fails. A device match no longer shows iOS's "Allow Paste" prompt. Same `openId`
  across both attempts; one event. `claimHandoff` is unchanged.
- Store sheet (beta): `StraitLinks.openStoreSheet(url, opener, [options])` calls
  `POST /v1/store-sheet`, then on Android tries Google Play inline install, `market://` and the Play
  web page (referrer carries `strait_link` + `strait_click`); on iPhone saves the device match
  (`/v1/match-save`), optionally copies the handoff link, and shows the App Store through your
  `StoreSheetOpener` (MethodChannel example in the README). New `lib/src/store_sheet.dart`.
- Docs and tests only, no code change. README gains a Support section; AGENTS.md gains a
  "stop and ask the human" list (signup and keys, handle, dashboard app settings, signing and
  store builds, the real-phone test) and a no-phone verify loop (`/v1/tools/app-links`,
  `/v1/simulate`), and says plainly that the package is not on pub.dev yet.
- Demo names: test and doc hosts move to reserved names (`hilltop.links.test`,
  `go.hilltop.example`, `jo@hilltop.example`); `conformance-vectors.json` re-copied from
  shared-spec 11779b1 (inputs renamed, every expected value unchanged).
- Old Firebase Dynamic Links (shared-spec/SDK-CONTRACT.md B22, conformance vectors v8). Add your
  `<x>.page.link` host to `linkHosts` (and keep `applinks:<x>.page.link` / the page.link intent filter in
  your app build): a page.link **short** link is looked up through `/v1/resolve` like any short link (the
  engine matches the old host + code of links you imported), and a page.link **long** link
  (`https://<x>.page.link/?link=<url>&…`) opens its `link=` destination straight away, on the device, with no
  lookup. Only `*.page.link` hosts at the root path, only an http(s) `link`. New core function
  `pageLinkLongLink`. Not yet tested on a real iPhone.

## 0.8.1

- First version meant for pub.dev: the package is built with `.pubignore`, so tests,
  CI, release tooling and internal `COUNCIL-*.md` notes stay out of the published archive.
  No API removed or renamed; 0.8.0 apps update without code changes.
- Referral codes (preview; shared-spec/proposals/referral-code.md, B21): a matched
  deferred `LinkEvent` (Play referrer, iPhone match, clipboard claim, `claimHandoff`)
  carries `referralCode` when the engine's reply has a valid one (also in `toJson`).
  Legacy `MatchResult.referralCode` too. New core function `replyReferralCode`.
  (This code is already in the `v0.8.0` tag; its changelog listed it under Unreleased.)

## 0.8.0

- Optional iPhone clipboard boost (shared-spec/SDK-CONTRACT.md B19). New config
  `clipboardBoost` (default **false**) and an app-supplied `StraitClipboard` adapter
  (`hasProbableWebUrl`, `readText`; README shows a MethodChannel version). With it on, the
  once-per-install check on iOS asks without a prompt whether the clipboard holds a web URL,
  reads it only then (iOS shows its paste prompt), and claims a Strait handoff link via
  `POST /v1/handoff/claim` for an exact match (`LinkRoute.clipboard`), else falls back to the
  signal match. With it off (the default) the clipboard is never touched.
- New `claimHandoff(text)` for a paste button (no prompt).
- New core export `parseHandoffUrl` (conformance vectors v7).

## 0.7.2

- Privacy hardening (shared-spec/SDK-CONTRACT.md B18): the URL sent with an open report
  (`/v1/open`, `/v1/resolve`) and saved in the offline queue (`strait.pendingOpens`) no
  longer carries the query string or fragment, except the first `utm_source` pair, which
  the engine uses for channel attribution. Reports queued by an older version are
  stripped the next time the queue is read. Your app's `LinkEvent` (`rawUrl`, `url`,
  `params`) is unchanged, and so is what the engine records.
- An expired remembered tap id (`strait.lastTap`, older than 7 days) is now deleted at
  `start()` and by `trackEvent`, instead of only being ignored.
- New core exports: `reportUrl`, `staleTap` (conformance vectors v6).

## 0.7.1

- Report the portrait screen width so a first launch in landscape still matches the tap
  (shared-spec/SDK-CONTRACT.md B17): new core export `portraitScreenWidth(width, height)`
  (the shorter side, rounded like the browser; conformance vectors v5). Build
  `DeviceFields.screenWidth` with it, as the README now shows.

## 0.7.0

- Every attributed open now supplies the tap id (shared-spec/SDK-CONTRACT.md B16):
  when `/v1/resolve` (verified short link), `/v1/match` (fingerprint) or
  `/v1/referrer` (Play install) returns `clickId`, it is remembered as
  `strait.lastTap` and sent with conversion events. A reply without one (older
  engine) keeps the 0.6.0 behaviour.
- New core export: `replyClickId` (conformance vectors v4).

## 0.6.0

- Conversion events carry the tap id (shared-spec/SDK-CONTRACT.md B15): the tap id
  of the last attributed link open (browser hand-off `strait_click`, or the Play
  referrer on a deferred install) is remembered under `strait.lastTap` and sent as
  `clickId` with `trackEvent` for 7 days. A newer short-link or fingerprint open
  forgets it. `trackEvent(name, clickId: …)` overrides it.
- New core exports: `eventClickId`, `rememberTap`, `attributionWindowMs`
  (conformance vectors v3).

## 0.5.0

- **Breaking: renamed to Strait.** The package is now `strait_sdk`
  (`import 'package:strait_sdk/strait_sdk.dart';`). `BridgeLinks` →
  `StraitLinks`, `parseBridgeLink` → `parseStraitLink`, `parseBridgeClick` →
  `parseStraitClick`; `lib/src/bridge.dart` → `lib/src/strait.dart`.
- **Breaking (clean break, no aliases):** wire params are now `strait_click`
  and `strait_link` (Play Install Referrer and hand-off URLs); the old
  `bridge_*` names are no longer read. Storage keys are now `strait.*`
  (`strait.deferredChecked`, `strait.pendingOpens`); values saved under the
  old keys are ignored, so a deferred link may be checked once more after
  upgrading.
- Publishable keys are issued as `st_pub_live_…` / `st_pub_test_…`.

## 0.4.0

- **New (contract B14):** every link open is reported exactly once. Each open
  gets an id from `newOpenId` (`o_<base36 ms>_<12 chars>`), also used as the
  `LinkEvent.id`. Short links send `openId`, `appState`, `firstLaunch`, `at`
  with `/v1/resolve` (falling back to `/v1/open` when the engine didn't record
  it); custom-scheme hand-offs and your own https links are reported via
  `POST /v1/open` without delaying the event. Unsent reports are kept in
  `storage` under `bridge.pendingOpens` and retried on start, on resume and
  after any successful report (≤7 days, ≤100). New `pendingOpenReports()` and
  `flushOpenReports()`.
- **New (B4):** a `bridge_click` tap id is removed from the destination
  (`takeClickId`) and returned as `ClassifiedUrl.clickId`.
- **Changed (B6/B7/B8):** the deferred check is marked done only once the
  engine answered (no answer / 429 / 5xx → `reason: 'network'`, retried next
  launch). The once-per-install run sends `openId` + `at` on `/v1/referrer`
  and `/v1/match`, plus the tap id (`parseBridgeClick`) on `/v1/referrer`;
  `checkDeferred()` sends neither.
- **New pure helpers:** `parseBridgeClick`, `takeClickId`, `pruneOpenQueue`,
  `shouldRetryReport`, `newOpenId`, `openQueueMax`, `openQueueMaxAgeMs` —
  checked against conformance vectors v2.

### Packaging

- Publish-ready for pub.dev: homepage / repository / issue_tracker / topics,
  MIT `LICENSE`, an `example/`, and `.pubignore` so tests, fixtures and repo
  tooling don't ship. `dart pub publish --dry-run` reports 0 warnings.
- The package name and URLs come from `brand.json` (applied by
  `scripts/brand.mjs`), so the brand switch is one command.
- Tag `vX.Y.Z` → GitHub Actions runs analyze + tests and publishes via pub.dev
  automated publishing (OIDC, no stored secret). See PUBLISHING.md.

## 0.3.0

- **New:** `BridgeLinks` client — full parity with the React Native SDK
  (`shared-spec/SDK-CONTRACT.md` B1–B13): direct links (verified App Links /
  Universal Links resolved via `POST /v1/resolve`, custom-scheme hand-offs),
  deferred links once per install (`bridge.deferredChecked`), `onLink` stream
  with replay, `onLinkStart` loading signal, app-state labels
  (closed/background/foreground), `checkDeferred`, `reportFingerprint`,
  `compareFingerprint`, `trackEvent`. Never throws; network failure →
  `matched: false, reason: 'network'`.
- **New:** pure helpers in `core.dart` — `browserScreenWidth`, `splitUrl`,
  `classifyUrl`, `AppStateTracker` — checked against
  `test/conformance-vectors.json`.
- **Fix:** `parseBridgeLink` now matches the contract exactly (first
  `bridge_link` pair wins; empty value → null). Moved to `core.dart`; still
  exported from the same places.
- `resolveDeferredLink` is unchanged and still supported.

## 0.2.0

- **Breaking:** `resolveDeferredLink` now takes `publishableKey` (your workspace
  publishable key, `bk_pub_live_…` / `bk_pub_test_…`, from Dashboard → Get started)
  instead of `appId`. Requests to `/v1/match` and `/v1/referrer` send
  `publishableKey` in the JSON body; the server rejects requests without it (401).

## 0.1.0

- Initial release: deferred deep-link resolution (Android Install Referrer,
  iOS/Android device-fingerprint match).
