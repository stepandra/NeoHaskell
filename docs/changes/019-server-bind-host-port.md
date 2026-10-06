# Change 019: Make the Warp bind host and port configurable

The web server always bound Warp's default host on a port fixed in code, so an
app running behind a reverse proxy could not restrict itself to loopback and
could not choose its port without building a `WebTransport` by hand. The
maintainer accepted a loopback-bind fix and asked to "make the port configurable
too". `WebTransport` gains a `host` field (default `"*"`, all interfaces, so
behaviour is unchanged) and `Application` gains `withHost` and `withPort`
builders next to the other `with*` builders. `runTransport` now starts Warp with
`runSettings` built from that host and port, and logs `<host>:<port>`.

```yaml spec
issue: adhoc:server-bind-host-port
kind: feature
touches: [http-transport]
breaking: true
new-dependency: false
new-capability: false
new-extension-point: false
```

## Contract delta

`WebTransport` and `Application` are public records, so adding a field changes
their constructor signature lines (a `-`/`+` pair each). `runTransports` gains
the two optional overrides that carry `withHost` / `withPort` to the transport.
`hostPreference` and `warpSettings` are the small, testable conversion from the
transport's host and port to Warp settings.

```diff signatures
- Service.Application: Application :: Maybe ConfigSpec -> Maybe EventStoreFactory -> Maybe QueryObjectStoreConfigValue -> Array QueryDefinition -> QueryRegistry -> Array ServiceRunner -> Map Text TransportValue -> Map Text QueryEndpointHandler -> Array OutboundRunner -> Array OutboundLifecycleRunner -> Array Inbound -> Maybe WebAuthFactory -> Maybe OAuth2Setup -> Maybe FileUploadFactory -> Maybe SecretStore -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe DispatcherConfig -> Maybe CorsFactory -> Maybe ApiInfoFactory -> Maybe HealthCheckFactory -> Maybe DispatcherConfigFactory -> Maybe SecretStoreFactory -> Array DeferredOutboundLifecycleReg -> Array DeferredInboundReg -> Array IntegrationRegistrationEntry -> Maybe ReadinessConfig -> Application
+ Service.Application: Application :: Maybe ConfigSpec -> Maybe EventStoreFactory -> Maybe QueryObjectStoreConfigValue -> Array QueryDefinition -> QueryRegistry -> Array ServiceRunner -> Map Text TransportValue -> Map Text QueryEndpointHandler -> Array OutboundRunner -> Array OutboundLifecycleRunner -> Array Inbound -> Maybe WebAuthFactory -> Maybe OAuth2Setup -> Maybe FileUploadFactory -> Maybe SecretStore -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe DispatcherConfig -> Maybe CorsFactory -> Maybe ApiInfoFactory -> Maybe HealthCheckFactory -> Maybe DispatcherConfigFactory -> Maybe SecretStoreFactory -> Array DeferredOutboundLifecycleReg -> Array DeferredInboundReg -> Array IntegrationRegistrationEntry -> Maybe ReadinessConfig -> Maybe Text -> Maybe Int -> Application
+ Service.Application: [bindHost] :: Application -> Maybe Text
+ Service.Application: [bindPort] :: Application -> Maybe Int
+ Service.Application: withHost :: Text -> Application -> Application
+ Service.Application: withPort :: Int -> Application -> Application
- Service.Application.Transports: runTransports :: Map Text TransportValue -> Map Text (Map Text EndpointHandler) -> Map Text (Map Text EndpointSchema) -> Map Text QueryEndpointHandler -> Map Text EndpointSchema -> Maybe AuthEnabled -> Maybe OAuth2Config -> Maybe FileUploadEnabled -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe IntegrationStatus -> Maybe ReadinessConfig -> QuerySubscriber -> Task Text Unit
+ Service.Application.Transports: runTransports :: Map Text TransportValue -> Map Text (Map Text EndpointHandler) -> Map Text (Map Text EndpointSchema) -> Map Text QueryEndpointHandler -> Map Text EndpointSchema -> Maybe AuthEnabled -> Maybe OAuth2Config -> Maybe FileUploadEnabled -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe IntegrationStatus -> Maybe ReadinessConfig -> Maybe Text -> Maybe Int -> QuerySubscriber -> Task Text Unit
- Service.Transport.Web: WebTransport :: Int -> Int -> Maybe AuthEnabled -> Maybe OAuth2Config -> Maybe FileUploadEnabled -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe IntegrationStatus -> Maybe ReadinessConfig -> Maybe (Task Text Readiness) -> WebTransport
+ Service.Transport.Web: WebTransport :: Int -> Text -> Int -> Maybe AuthEnabled -> Maybe OAuth2Config -> Maybe FileUploadEnabled -> Maybe ApiInfo -> Maybe CorsConfig -> Maybe HealthCheckConfig -> Maybe IntegrationStatus -> Maybe ReadinessConfig -> Maybe (Task Text Readiness) -> WebTransport
+ Service.Transport.Web: [host] :: WebTransport -> Text
+ Service.Transport.Web: hostPreference :: Text -> HostPreference
+ Service.Transport.Web: warpSettings :: WebTransport -> Settings
```

## Criteria

| ID | Behavior | Proving test | Level | Boundary |
|----|----------|--------------|-------|----------|
| C1 | `WebTransport` binds all interfaces on port 8080 by default, exactly as before | `hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#server binds all interfaces by default`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#server listens on port 8080 by default` | unit | none |
| C2 | `Application.withHost` / `Application.withPort` record the bind host and port, and a new `Application` leaves them unset | `hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#withHost records the bind host`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#withPort records the bind port`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#bind host and port are unset on a new Application` | unit | none |
| C3 | The host text maps to the right Warp `HostPreference` (`127.0.0.1`, `*`, `*4`, `*6`, `::1`) | `hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#maps a literal IPv4 address to that host`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#maps * to all interfaces`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#maps *4 to all IPv4 interfaces`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#maps *6 to all IPv6 interfaces`<br>`hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#maps a literal IPv6 address to that host` | unit | none |
| C4 | The Warp settings the transport runs with carry the configured host and port | `hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#carries the configured host and port into Warp` | unit | none |
| C5 | An application started with `withHost "127.0.0.1"` and `withPort <free port>` answers `GET /health` on loopback | `hspec:nhcore-test-service:core/test/Service/Transport/Web/BindSpec.hs#serves /health on loopback when bound to 127.0.0.1` | unit | none |

## User impact

Breaking only for code that builds the records positionally or with every field
named; nothing else changes. Apps that use `WebTransport.server`, including
`server { port = ... }`, and apps built with `Application.new` and the `with*`
builders are unaffected and keep binding all interfaces on port 8080 unless they
opt in. Migration: a program that writes `WebTransport { ... }` with all fields
must add `host = "*"` (the previous behaviour) or `host = "127.0.0.1"` for
loopback only; a program that writes `Application { ... }` with all fields must
add `bindHost = Nothing` and `bindPort = Nothing`. The testbed uses
`WebTransport.server` with no overrides, so its behaviour is unchanged.
New ways to use it: `Application.withHost "127.0.0.1"` and
`Application.withPort 9090`; `host` also accepts `"*"`, `"*4"`, `"*6"` or a
literal address.

## ADR

[ADR-0079](../decisions/0079-configurable-web-bind-host-and-port.md): why the
default stays `"*"` and why the overrides live on `Application`.
