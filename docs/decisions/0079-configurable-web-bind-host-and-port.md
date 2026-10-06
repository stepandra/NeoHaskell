# ADR-0079: Configurable web bind host and port

## Status

Accepted

## Context

`WebTransport` always bound Warp's default host and a port fixed in `server`.
Apps behind a reverse proxy want loopback-only binding, and the port could only
be changed by editing the `WebTransport` record, which `Application` hides
inside an existing transport value. The maintainer accepted a loopback-bind fix
and asked for the port to be configurable too.

## Decision

Add `host :: Text` to `WebTransport` and start Warp with `runSettings`, using
`setPort` and `setHost`. The text maps to Warp's `HostPreference`: `"*"` all
interfaces, `"*4"`, `"*6"`, or a literal address such as `"127.0.0.1"`.

The default is `"*4"`: exactly what the previous `Warp.run` bound (all IPv4
interfaces). A loopback default would silently break containers and any app
that is reached from another machine; a `"*"` default would silently start
listening on IPv6 too, a new reachable surface on dual-stack hosts whose
firewall rules only cover IPv4. Neither change belongs in a "make it
configurable" PR, so both loopback-only and IPv6 are opt-in through `withHost`.

Add `Application.withHost` and `Application.withPort`, stored as `bindHost` and
`bindPort` and applied when the web transport starts. They are on `Application`,
like `withCors` and `withHealthCheck`, because `withTransport` stores the
transport as an opaque value, so a builder cannot edit it. The override applies
whatever the order of `withTransport` and the builder.

## Consequences

- Constructing `WebTransport` or `Application` with every field named must add
  the new fields. This is the one breaking effect; `WebTransport.server` users
  are unaffected.
- Apps can bind loopback only, or choose the port, in one line.
- The start-up log now shows `<host>:<port>`.
- The default now also accepts IPv6 connections (it was IPv4 only). Apps that
  need IPv4 only can set `"*4"`.
