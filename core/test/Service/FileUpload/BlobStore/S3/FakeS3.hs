-- | In-process fake of the S3 object API, just enough for the S3 BlobStore
-- facade: PUT / GET / HEAD / DELETE on @/bucket/key@ with ETag headers and
-- 200 / 204 / 404 / 403 answers. It speaks the S3 wire protocol and nothing
-- else.
--
-- Boundary (deliberate, per maintainer request): this module depends only on
-- wai/warp and Core. It imports nothing from the FileUpload service or from
-- other test infrastructure, and only the S3 specs import it, so it can move
-- with the S3 backend if the package is split.
--
-- The signature is not verified cryptographically here (SigV4Spec covers the
-- algorithm against the AWS vectors); the fake checks that every request
-- carries the SigV4 headers and the configured access key, and can be
-- switched to reject everything with 403.
module Service.FileUpload.BlobStore.S3.FakeS3 (
  FakeS3 (..),
  Mode (..),
  withFakeS3,
  objects,
) where

import Array (Array)
import Array qualified
import Basics
import Bytes (Bytes)
import Bytes qualified
import ConcurrentMap (ConcurrentMap)
import ConcurrentMap qualified
import ConcurrentVar (ConcurrentVar)
import ConcurrentVar qualified
import Maybe (Maybe (..))
import Maybe qualified
import Task (Task)
import Task qualified
import Text (Text)
import Text qualified

-- Transport only: WAI/Warp are the HTTP server core already depends on.
import Control.Concurrent qualified as GhcConcurrent
import Data.ByteString.Lazy qualified as GhcLBS
import Data.CaseInsensitive qualified as GhcCI
import Network.HTTP.Types qualified as GhcHTTP
import Network.Socket qualified as GhcSocket
import Network.Wai qualified as GhcWai
import Network.Wai.Handler.Warp qualified as GhcWarp


-- | How the fake answers signed requests.
data Mode
  = Accept
  -- ^ Normal S3 behaviour.
  | Forbid
  -- ^ Every request answers 403 (wrong credentials / policy denial).
  deriving (Eq, Show)


data FakeS3 = FakeS3
  { port :: Int
  , endpoint :: Text
  -- ^ @http://127.0.0.1:PORT@
  , bucket :: Text
  , accessKeyId :: Text
  , mode :: ConcurrentVar Mode
  , store :: ConcurrentMap Text Bytes
  -- ^ Objects by full path (@/bucket/key@) as received on the wire.
  , requests :: ConcurrentVar (Array (Text, Text))
  -- ^ (method, path) of every request seen, oldest first.
  }


-- | Run a fake S3 on a free loopback port for the duration of the action.
withFakeS3 :: Text -> Text -> (FakeS3 -> Task Text Unit) -> Task Text Unit
withFakeS3 bucket accessKeyId action = do
  port <- getFreePort
  mode <- ConcurrentVar.containing Accept
  store <- ConcurrentMap.new
  requests <- ConcurrentVar.containing Array.empty
  let fake =
        FakeS3
          { port
          , endpoint = [fmt|http://127.0.0.1:#{port}|]
          , bucket
          , accessKeyId
          , mode
          , store
          , requests
          }
  serverThread <- GhcConcurrent.forkIO (GhcWarp.run port (application fake)) |> Task.fromIO
  GhcConcurrent.threadDelay 50000 |> Task.fromIO
  let cleanup = GhcConcurrent.killThread serverThread |> Task.fromIO
  action fake |> Task.finally cleanup


-- | Current object paths, for assertions.
objects :: FakeS3 -> Task Text (Array Text)
objects fake = ConcurrentMap.keys fake.store


-- ==========================================================================
-- WAI application
-- ==========================================================================

application :: FakeS3 -> GhcWai.Application
application fake request respond = do
  let method = GhcWai.requestMethod request |> Bytes.fromLegacy |> Text.fromBytes
  let path = GhcWai.rawPathInfo request |> Bytes.fromLegacy |> Text.fromBytes
  body <- GhcWai.strictRequestBody request
  let headers =
        GhcWai.requestHeaders request
          |> Array.fromLinkedList
          |> Array.map (\(name, value) -> (headerNameText name, value |> Bytes.fromLegacy |> Text.fromBytes))
  response <-
    handle fake method path headers (body |> Bytes.fromLazyLegacy)
      |> Task.runOrPanic
  respond response


headerNameText :: GhcHTTP.HeaderName -> Text
headerNameText name = GhcCI.original name |> Bytes.fromLegacy |> Text.fromBytes |> Text.toLower


handle :: FakeS3 -> Text -> Text -> Array (Text, Text) -> Bytes -> Task Text GhcWai.Response
handle fake method path headers body = do
  ConcurrentVar.modify (Array.push (method, path)) fake.requests
  mode <- ConcurrentVar.peek fake.mode
  let bucket = fake.bucket
  let bucketPrefix = [fmt|/#{bucket}/|] :: Text
  if not (isSigned fake headers)
    then Task.yield (xmlError GhcHTTP.status403 "AccessDenied")
    else
      if mode == Forbid
        then Task.yield (xmlError GhcHTTP.status403 "AccessDenied")
        else
          if not (Text.startsWith bucketPrefix path)
            then Task.yield (xmlError GhcHTTP.status404 "NoSuchBucket")
            else dispatch fake method path body


-- | SigV4 header-based auth always carries these three; the Credential must
-- name the configured access key.
isSigned :: FakeS3 -> Array (Text, Text) -> Bool
isSigned fake headers = do
  let header name = headers |> Array.find (\(key, _) -> key == name) |> Maybe.map (\(_, value) -> value)
  let accessKey = fake.accessKeyId
  let expectedCredential = [fmt|AWS4-HMAC-SHA256 Credential=#{accessKey}/|] :: Text
  let present name = case header name of
        Nothing -> False
        Just _ -> True
  let authorized = case header "authorization" of
        Nothing -> False
        Just value -> Text.startsWith expectedCredential value && Text.contains ", Signature=" value
  authorized && present "x-amz-date" && present "x-amz-content-sha256"


dispatch :: FakeS3 -> Text -> Text -> Bytes -> Task Text GhcWai.Response
dispatch fake method path body =
  case method of
    "PUT" -> do
      ConcurrentMap.set path body fake.store
      Task.yield (plain GhcHTTP.status200 [("ETag", etagOf body)] Bytes.empty)
    "GET" -> do
      stored <- ConcurrentMap.get path fake.store
      case stored of
        Nothing -> Task.yield (xmlError GhcHTTP.status404 "NoSuchKey")
        Just bytes -> Task.yield (plain GhcHTTP.status200 [("ETag", etagOf bytes)] bytes)
    "HEAD" -> do
      stored <- ConcurrentMap.get path fake.store
      case stored of
        Nothing -> Task.yield (plain GhcHTTP.status404 [] Bytes.empty)
        Just bytes -> Task.yield (plain GhcHTTP.status200 [("ETag", etagOf bytes)] Bytes.empty)
    "DELETE" -> do
      ConcurrentMap.remove path fake.store
      Task.yield (plain GhcHTTP.status204 [] Bytes.empty)
    _ -> Task.yield (xmlError GhcHTTP.status405 "MethodNotAllowed")


-- | Opaque but deterministic per content, like a real single-part ETag.
etagOf :: Bytes -> Text
etagOf bytes = do
  let size = Bytes.length bytes
  let tag = bytes |> Bytes.toBase64 |> Text.fromBytes |> Text.left 16
  [fmt|"#{tag}-#{size}"|]


plain :: GhcHTTP.Status -> Array (Text, Text) -> Bytes -> GhcWai.Response
plain status headers body =
  GhcWai.responseLBS
    status
    (headers |> Array.map (\(name, value) -> (name |> Text.toBytes |> Bytes.unwrap |> GhcCI.mk, value |> Text.toBytes |> Bytes.unwrap)) |> Array.toLinkedList)
    (Bytes.toLazyLegacy body)


xmlError :: GhcHTTP.Status -> Text -> GhcWai.Response
xmlError status code =
  GhcWai.responseLBS
    status
    [(GhcHTTP.hContentType, "application/xml")]
    (GhcLBS.fromStrict ([fmt|<Error><Code>#{code}</Code></Error>|] |> Text.toBytes |> Bytes.unwrap))


-- | Bind port 0 on loopback, read the assigned port, release it.
getFreePort :: Task Text Int
getFreePort =
  Task.fromIO do
    let hints = GhcSocket.defaultHints {GhcSocket.addrSocketType = GhcSocket.Stream}
    addrInfos <- GhcSocket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
    case addrInfos of
      [] -> pure 19900 -- HOOK-ALLOW: IO boundary of the fake server
      (addr : _) -> do
        sock <- GhcSocket.openSocket addr
        GhcSocket.bind sock (GhcSocket.addrAddress addr)
        port <- GhcSocket.socketPort sock
        GhcSocket.close sock
        pure (fromIntegral port) -- HOOK-ALLOW: IO boundary of the fake server
