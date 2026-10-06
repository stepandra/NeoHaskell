---
group: platform
component: Framework
impact: breaking
category: Breaking changes
---

## Summary

You can now choose which network address and port your web server listens on. Add `Application.withHost "127.0.0.1"` to accept connections from the same machine only, which is the safe choice behind a reverse proxy, and `Application.withPort 9090` to change the port. `host` also accepts `"*"` (all addresses, IPv4 and IPv6), `"*4"`, `"*6"` or a literal address.

Your app behaves as before unless you opt in: it still listens on all addresses on port 8080. It now also accepts IPv6 connections; use `"*4"` for IPv4 only.

This is marked breaking for one narrow case. `WebTransport` and `Application` each gained fields, so code that builds either record by naming every field must add the new ones. Apps that use `WebTransport.server` or `Application.new` are not affected and need no change.

## Migration

Search your code for a `WebTransport { ... }` or `Application { ... }` record written with every field. Most apps have none and can stop here.

- In a `WebTransport { ... }` record, add `host = "*"` to keep the old behaviour, or `host = "127.0.0.1"` to accept local connections only.
- In an `Application { ... }` record, add `bindHost = Nothing` and `bindPort = Nothing`.

Prefer `WebTransport.server { port = 9090 }` or `Application.withHost` and `Application.withPort` over naming every field.

### Verify

Build your app, then start it and request `/health` on the address you chose. To check the framework change itself, run `./dev test "Service.Transport.Web.Bind" nhcore-test-service`. All 12 examples pass, including one that starts the server on `127.0.0.1` and fetches `/health`.

## Agent prompt

```text
My NeoHaskell app fails to compile after upgrading nhcore. `WebTransport` gained a `host :: Text` field and `Application` gained `bindHost :: Maybe Text` and `bindPort :: Maybe Int`. Find every place that builds a `WebTransport { ... }` or `Application { ... }` record by naming all fields (search for `WebTransport {`, `WebTransport$` followed by `{`, and `Application {`). In each `WebTransport` record add `host = "*"` so it keeps listening on all addresses. In each `Application` record add `bindHost = Nothing` and `bindPort = Nothing`. Do not change anything that uses `WebTransport.server` or `Application.new`. Keep the port and every other field exactly as they were. Then build the project and run its tests. Report which files you edited and whether the build and tests pass. If my app sits behind a reverse proxy, tell me I can use `Application.withHost "127.0.0.1"` for local-only access, but do not change it without asking.
```
