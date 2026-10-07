module Service.Transport.Web.BindSpec where

import AsyncTask qualified
import Core
import Http.Client qualified as Http
import Http.Client.Internal qualified as HttpInternal
import Network.Socket qualified as GhcSocket
import Network.Wai.Handler.Warp qualified as GhcWarp
import Service.Application (Application (..))
import Service.Application qualified as Application
import Service.EventStore.InMemory qualified as InMemory
import Service.Transport.Web (WebTransport (..), applyBindOverrides, hostPreference, server, warpSettings)
import Task qualified
import Test


spec :: Spec Unit
spec = do
  describe "WebTransport bind host and port" do
    describe "defaults" do
      it "server binds all IPv4 interfaces by default (unchanged from Warp.run)" \_ -> do
        server.host |> shouldBe "*4"

      it "server listens on port 8080 by default" \_ -> do
        server.port |> shouldBe 8080

    describe "Application builders" do
      it "withHost records the bind host" \_ -> do
        let app = Application.new |> Application.withHost "127.0.0.1"
        app.bindHost |> shouldBe (Just "127.0.0.1")

      it "withPort records the bind port" \_ -> do
        let app = Application.new |> Application.withPort 9090
        app.bindPort |> shouldBe (Just 9090)

      it "bind host and port are unset on a new Application" \_ -> do
        Application.new.bindHost |> shouldBe Nothing
        Application.new.bindPort |> shouldBe Nothing

    describe "hostPreference" do
      it "maps a literal IPv4 address to that host" \_ -> do
        show (hostPreference "127.0.0.1") |> shouldBe "Host \"127.0.0.1\""

      it "maps * to all interfaces" \_ -> do
        show (hostPreference "*") |> shouldBe "HostAny"

      it "maps *4 to all IPv4 interfaces" \_ -> do
        show (hostPreference "*4") |> shouldBe "HostIPv4"

      it "maps *6 to all IPv6 interfaces" \_ -> do
        show (hostPreference "*6") |> shouldBe "HostIPv6"

      it "maps a literal IPv6 address to that host" \_ -> do
        show (hostPreference "::1") |> shouldBe "Host \"::1\""

    describe "override composition" do
      it "withHost and withPort apply whether they come before or after withTransport" \_ -> do
        let before =
              Application.new
                |> Application.withHost "127.0.0.1"
                |> Application.withPort 9191
                |> Application.withTransport server
        let after =
              Application.new
                |> Application.withTransport server
                |> Application.withHost "127.0.0.1"
                |> Application.withPort 9191
        let bound app = applyBindOverrides app.bindHost app.bindPort server
        (bound before).host |> shouldBe "127.0.0.1"
        (bound before).port |> shouldBe 9191
        (bound after).host |> shouldBe "127.0.0.1"
        (bound after).port |> shouldBe 9191

      it "absent overrides preserve the transport's custom host and port" \_ -> do
        let custom = server {host = "::1", port = 7070}
        let untouched = applyBindOverrides Nothing Nothing custom
        untouched.host |> shouldBe "::1"
        untouched.port |> shouldBe 7070
        let hostOnly = applyBindOverrides (Just "127.0.0.1") Nothing custom
        hostOnly.host |> shouldBe "127.0.0.1"
        hostOnly.port |> shouldBe 7070
        let portOnly = applyBindOverrides Nothing (Just 9191) custom
        portOnly.host |> shouldBe "::1"
        portOnly.port |> shouldBe 9191

    describe "warpSettings" do
      it "carries the configured host and port into Warp" \_ -> do
        let transport = server {host = "127.0.0.1", port = 9191}
        let settings = warpSettings transport
        show (GhcWarp.getHost settings) |> shouldBe "Host \"127.0.0.1\""
        GhcWarp.getPort settings |> shouldBe 9191

    describe "running" do
      it "serves /health on loopback when bound to 127.0.0.1" \_ -> do
        eventStore <- InMemory.new |> Task.mapError toText
        freePort <- getFreePort
        let app =
              Application.new
                |> Application.withTransport server
                |> Application.withHost "127.0.0.1"
                |> Application.withPort freePort
        running <- AsyncTask.run (Application.runWith eventStore app)
        let cancelApp = AsyncTask.cancel running |> Task.ignoreError
        let probe = do
              status <- getHealthStatus freePort 50
              status |> shouldBe 200
        probe |> Task.finally cancelApp


-- | Ask the OS for a currently free loopback port.
getFreePort :: Task Text Int
getFreePort = do
  let hints = GhcSocket.defaultHints {GhcSocket.addrSocketType = GhcSocket.Stream}
  addrInfos <- GhcSocket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0") |> Task.fromIO
  case addrInfos of
    [] -> Task.throw "no loopback address available"
    (addr : _) -> do
      sock <- GhcSocket.openSocket addr |> Task.fromIO
      GhcSocket.bind sock (GhcSocket.addrAddress addr) |> Task.fromIO
      port <- GhcSocket.socketPort sock |> Task.fromIO
      GhcSocket.close sock |> Task.fromIO
      Task.yield (fromIntegral port)


-- | GET /health on loopback, retrying while the server is still binding.
getHealthStatus :: Int -> Int -> Task Text Int
getHealthStatus port attemptsLeft = do
  result <-
    Http.request
      |> Http.withUrl [fmt|http://127.0.0.1:#{port}/health|]
      |> Http.withTimeout 2
      |> HttpInternal.getRaw
      |> Task.asResult
  case result of
    Ok response -> Task.yield response.statusCode
    Err _ ->
      if attemptsLeft <= 0
        then Task.throw "/health never answered on the bound loopback port"
        else do
          AsyncTask.sleep 100
          getHealthStatus port (attemptsLeft - 1)
