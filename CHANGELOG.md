# Changelog

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
