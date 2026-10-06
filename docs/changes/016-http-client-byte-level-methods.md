# Change 016: Add byte-level HTTP methods (PUT/HEAD/DELETE…) to Http.Client

Protocol clients inside nhcore need to talk to object stores and similar REST
services: send a raw byte body with PUT, probe with HEAD, DELETE, read the
status code and headers (e.g. `ETag`) of every response including 4xx, and
never follow redirects. Today `Http.Client` offers byte-level, non-throwing
responses only for GET (`getSecure`, `Http.Client.Internal.getRaw`); the other
verbs decode JSON and throw on non-2xx. This change generalizes the existing
GET path into one method-agnostic primitive so the upcoming S3 `BlobStore`
(change 017) can use the Core HTTP client instead of raw `http-client`, as the
maintainer requested ("extend `Http.Client`" rather than adding a transport).

```yaml spec
issue: adhoc:http-client-byte-level-methods
kind: feature
touches: [http-client]
breaking: false
new-dependency: false
new-capability: false
new-extension-point: false
```

## Contract delta

`getSecure` and `getRaw` keep their signatures and become `Get` specializations
of the new functions. `sendSecure` enforces `https://` exactly like
`getSecure`; `sendRaw` is the loopback-only twin exported from
`Http.Client.Internal`, mirroring the existing `getRaw` split. Both reuse the
existing request options (headers, timeout, `maxRedirects = 0` default, proxy
disabled, `maxResponseBytes` limit) and the pinned TLS 1.2+ manager.

```diff signatures
+ Http.Client: data Method = Get | Head | Post | Put | Patch | Delete
+ Http.Client: methodName :: Method -> Text
+ Http.Client: sendSecure :: Method -> Request -> Bytes -> Task Error (Response Bytes)
+ Http.Client.Internal: sendRaw :: Method -> Request -> Bytes -> Task Error (Response Bytes)
```

## Criteria

| ID | Behavior | Proving test | Level | Boundary |
|----|----------|--------------|-------|----------|
| C1 | A PUT delivers the wire method, the raw body and caller headers unchanged | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendRaw PUT delivers method, raw body and custom header` | unit | none |
| C2 | HEAD returns status and headers with an empty body and does not throw | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendRaw HEAD returns headers and an empty body without throwing` | unit | none |
| C3 | Non-2xx statuses (404, 403) are returned as `statusCode`, never as `Err` | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendRaw DELETE surfaces a 404 as a status code, not an error`<br>`hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendRaw PUT surfaces a 403 as a status code, not an error` | unit | none |
| C4 | The response-size limit applies to every method | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendRaw enforces maxResponseBytes on the response body` | unit | none |
| C5 | `sendSecure` rejects plain `http://` with a sanitized `InvalidUrl` | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#sendSecure rejects a plain http:// URL with InvalidUrl` | unit | none |
| C6 | `methodName` spells every wire token of the closed `Method` set | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#methodName spells every wire token` | unit | none |
| C7 | Existing GET behavior is unchanged (`getRaw` status/body/network-error cases) | `hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#returns Ok with statusCode 401 on 401 response`<br>`hspec:nhcore-test-core:core/test/Http/ClientRawSpec.hs#returns Err on network error` | unit | none |

The proving tests use the in-process Warp mock pattern already present in
`core/test/Http/ClientRawSpec.hs` (loopback, free port, no external service),
so they run in `nhcore-test-core` with boundary `none`.

## User impact

None breaking. `getSecure`/`getRaw` behave as before (GET, same errors, same
limits). New: `Http.Client.sendSecure` for HTTPS endpoints and
`Http.Client.Internal.sendRaw` for trusted loopback endpoints; both return the
status code instead of throwing on 4xx/5xx and never decode the body. Jess does
not need to change anything; integration authors gain PUT/HEAD/DELETE with raw
bodies without importing `Network.HTTP.Client`.

## ADR

Not required — no trigger (breaking / new-dependency / new-capability /
new-extension-point all false). Design note: the maintainer rule "if we can do
it ourselves without much complexity, do it ourselves; if too much, use a
Hackage package; for this one extend `Http.Client`" is satisfied by ≈90 lines
that reuse the existing `getSecure` machinery (`applyRequestOptions`,
`checkContentLengthHeaderLimit`, `readBodyFully`, `cachedSecureTlsManager`).
