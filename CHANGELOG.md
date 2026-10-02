# Changelog

## 0.2.0

- **Breaking:** `resolveDeferredLink` now takes `publishableKey` (your workspace
  publishable key, `bk_pub_live_…` / `bk_pub_test_…`, from Dashboard → Get started)
  instead of `appId`. Requests to `/v1/match` and `/v1/referrer` send
  `publishableKey` in the JSON body; the server rejects requests without it (401).

## 0.1.0

- Initial release: deferred deep-link resolution (Android Install Referrer,
  iOS/Android device-fingerprint match).
