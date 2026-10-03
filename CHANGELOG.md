# Changelog

## 0.4.0

- **New (contract B14):** every link open is reported exactly once. Each open
  gets an id from `newOpenId` (`o_<base36 ms>_<12 chars>`), also used as the
  `LinkEvent.id`. Short links send `openId`, `appState`, `firstLaunch`, `at`
  with `/v1/resolve` (falling back to `/v1/open` when the engine didn't record
  it); custom-scheme hand-offs and your own https links are reported via
  `POST /v1/open` without delaying the event. Unsent reports are kept in
  `storage` under `strait.pendingOpens` and retried on start, on resume and
  after any successful report (≤7 days, ≤100). New `pendingOpenReports()` and
  `flushOpenReports()`.
- **New (B4):** a `strait_click` tap id is removed from the destination
  (`takeClickId`) and returned as `ClassifiedUrl.clickId`.
- **Changed (B6/B7/B8):** the deferred check is marked done only once the
  engine answered (no answer / 429 / 5xx → `reason: 'network'`, retried next
  launch). The once-per-install run sends `openId` + `at` on `/v1/referrer`
  and `/v1/match`, plus the tap id (`parseStraitClick`) on `/v1/referrer`;
  `checkDeferred()` sends neither.
- **New pure helpers:** `parseStraitClick`, `takeClickId`, `pruneOpenQueue`,
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

- **New:** `StraitLinks` client — full parity with the React Native SDK
  (`shared-spec/SDK-CONTRACT.md` B1–B13): direct links (verified App Links /
  Universal Links resolved via `POST /v1/resolve`, custom-scheme hand-offs),
  deferred links once per install (`strait.deferredChecked`), `onLink` stream
  with replay, `onLinkStart` loading signal, app-state labels
  (closed/background/foreground), `checkDeferred`, `reportFingerprint`,
  `compareFingerprint`, `trackEvent`. Never throws; network failure →
  `matched: false, reason: 'network'`.
- **New:** pure helpers in `core.dart` — `browserScreenWidth`, `splitUrl`,
  `classifyUrl`, `AppStateTracker` — checked against
  `test/conformance-vectors.json`.
- **Fix:** `parseStraitLink` now matches the contract exactly (first
  `strait_link` pair wins; empty value → null). Moved to `core.dart`; still
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
