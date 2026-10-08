-- | S3-compatible blob store (AWS S3, Cloudflare R2, Backblaze B2, MinIO,
-- RustFS, ...). Path-style addressing, SigV4 request signing, one HTTP
-- request per operation through the Core HTTP client.
--
-- Same shape as "Service.FileUpload.BlobStore.Local": the configuration record
-- owns everything the backend needs, and 'createBlobStore' is the only
-- constructor. The bucket must already exist. HTTPS is required unless the
-- endpoint is a literal loopback address (local fixtures and tests).
-- Redirects are never followed; nothing is retried, so a failed write has an
-- unknown outcome and surfaces as 'StorageError'.
--
-- Azure Blob Storage speaks a different protocol (SharedKey) and would be a
-- sibling module with this same shape, not a variant of this one.
module Service.FileUpload.BlobStore.S3 (
  -- * Configuration
  S3Config (..),

  -- * Constructor
  createBlobStore,
) where

import Array (Array)
import Array qualified
import Basics
import Bytes (Bytes)
import Bytes qualified
import Char qualified
import DateTime (DateTime)
import DateTime qualified
import Http.Client (Method (..), Request, Response)
import Http.Client qualified as Http
import Http.Client.Internal qualified as HttpInternal
import Maybe qualified
import Result (Result (..))
import Service.FileUpload.BlobStore (BlobStore (..), BlobStoreError (..))
import Service.FileUpload.BlobStore.S3.SigV4 (CanonicalRequest (..), Credentials (..))
import Service.FileUpload.BlobStore.S3.SigV4 qualified as SigV4
import Service.FileUpload.Core (BlobKey (..))
import Task (Task)
import Task qualified
import Text (Text)
import Text qualified


-- ==========================================================================
-- Configuration
-- ==========================================================================

-- | Configuration for an S3-compatible blob store.
--
-- Read the credentials from the application's own configuration (e.g. the
-- app's @Config.hs@) and build this record in @App.hs@; the blob store never
-- reads the environment itself. No 'Show' instance: the secret must not reach
-- logs.
data S3Config = S3Config
  { endpoint :: Text
  -- ^ Scheme, host and optional port only, e.g. @https://s3.eu-central-1.amazonaws.com@
  -- or @http://127.0.0.1:9000@. No path, query, fragment or userinfo.
  , bucket :: Text
  -- ^ Existing bucket; DNS-style name (3-63 chars of @a-z 0-9 - .@).
  , region :: Text
  -- ^ SigV4 region, e.g. @us-east-1@ (R2, B2 and MinIO accept @auto@ or @us-east-1@).
  , accessKeyId :: Text
  , secretAccessKey :: Text
  }


-- | Validated connection parameters derived once from 'S3Config'.
data S3Store = S3Store
  { baseUrl :: Text
  -- ^ Endpoint without trailing slash.
  , hostHeader :: Text
  -- ^ Host header value: host plus port when the port is not the scheme default.
  , secure :: Bool
  , bucketName :: Text
  , credentials :: Credentials
  }


-- ==========================================================================
-- Constructor
-- ==========================================================================

-- | Create an S3 blob store. Fails on an invalid configuration; does not
-- contact the endpoint.
createBlobStore :: S3Config -> Task Text BlobStore
createBlobStore config = do
  store <- validateConfig config
  Task.yield
    BlobStore
      { store = storeImpl store
      , retrieve = retrieveImpl store
      , delete = deleteImpl store
      , exists = existsImpl store
      }


-- ==========================================================================
-- Validation
-- ==========================================================================

-- | Check the endpoint scheme, bucket name and credentials once, before any request.
validateConfig :: S3Config -> Task Text S3Store
validateConfig config = do
  Task.when
    (Text.isEmpty config.bucket || Text.isEmpty config.region || Text.isEmpty config.accessKeyId || Text.isEmpty config.secretAccessKey)
    (Task.throw "S3 configuration fields must not be empty")
  Task.unless (isDnsBucketName config.bucket) (Task.throw "S3 bucket must be a DNS-style bucket name")
  endpoint <- parseEndpoint config.endpoint
  Task.yield
    S3Store
      { baseUrl = endpoint.url
      , hostHeader = endpoint.hostHeader
      , secure = endpoint.secure
      , bucketName = config.bucket
      , credentials =
          Credentials
            { accessKeyId = config.accessKeyId
            , secretAccessKey = config.secretAccessKey
            , region = config.region
            }
      }


-- | True for a bucket name that is valid in a path-style S3 URL: 3 to 63
-- lowercase ASCII letters, digits, hyphens and dots, where every dot-separated
-- label is non-empty and starts and ends with a letter or digit.
--
-- >>> isDnsBucketName "my-bucket.v2"
-- True
--
-- >>> isDnsBucketName "My_Bucket"
-- False
--
-- >>> isDnsBucketName "a..b"
-- False
isDnsBucketName :: Text -> Bool
isDnsBucketName name = do
  let validChar char = (Char.isLower char && Char.toCode char < 128) || Char.isDigit char || char == '-' || char == '.'
  let invalidLabel label = Text.isEmpty label || Text.startsWith "-" label || Text.endsWith "-" label
  Text.length name >= 3
    && Text.length name <= 63
    && Text.all validChar name
    && not (name |> Text.split "." |> Array.any invalidLabel)


data Endpoint = Endpoint
  { url :: Text
  , hostHeader :: Text
  , secure :: Bool
  }


-- | Accept @scheme://host[:port]@ only. HTTPS everywhere except literal loopback.
parseEndpoint :: Text -> Task Text Endpoint
parseEndpoint raw = do
  let trimmed = raw |> Text.trim |> stripTrailingSlash
  (isSecure, authority) <-
    if Text.startsWith "https://" trimmed
      then Task.yield (True, Text.dropLeft 8 trimmed)
      else
        if Text.startsWith "http://" trimmed
          then Task.yield (False, Text.dropLeft 7 trimmed)
          else Task.throw "S3 endpoint must start with https:// or http://"
  Task.when
    (Text.isEmpty authority || Text.any (\char -> char == '/' || char == '?' || char == '#' || char == '@' || char == ' ') authority)
    (Task.throw "S3 endpoint must not contain credentials, path, query or fragment")
  let host = hostOf authority
  Task.unless (isSecure || isLoopback host) (Task.throw "S3 requires HTTPS outside literal loopback")
  let defaultPort = if isSecure then ":443" else ":80"
  let hostHeader = if Text.endsWith defaultPort authority then host else authority
  Task.yield Endpoint {url = trimmed, hostHeader, secure = isSecure}


-- | Remove one trailing slash so paths join without doubling it.
stripTrailingSlash :: Text -> Text
stripTrailingSlash text = if Text.endsWith "/" text then Text.dropRight 1 text else text


-- | Host without the port; keeps IPv6 brackets ("[::1]:9000" -> "[::1]").
hostOf :: Text -> Text
hostOf authority =
  if Text.startsWith "[" authority
    then do
      let inside = Text.split "]" authority |> Array.first |> Maybe.withDefault authority
      [fmt|#{inside}]|]
    else Text.split ":" authority |> Array.first |> Maybe.withDefault authority


-- | True for literal loopback hosts, the only ones allowed over plain HTTP.
isLoopback :: Text -> Bool
isLoopback host = host == "127.0.0.1" || host == "localhost" || host == "[::1]"


-- ==========================================================================
-- Operations
-- ==========================================================================

-- | 'BlobStore.store': PUT the bytes; any non-2xx is a storage error.
storeImpl :: S3Store -> BlobKey -> Bytes -> Task BlobStoreError Unit
storeImpl store blobKey bytes = do
  response <- sendObject store Put blobKey bytes
  Task.unless (response.statusCode == 200) (Task.throw (statusError response))


-- | 'BlobStore.retrieve': GET; 404 is 'BlobNotFound', other non-2xx are errors.
retrieveImpl :: S3Store -> BlobKey -> Task BlobStoreError Bytes
retrieveImpl store blobKey = do
  response <- sendObject store Get blobKey Bytes.empty
  if response.statusCode == 200
    then Task.yield response.body
    else
      if response.statusCode == 404
        then Task.throw (NotFound blobKey)
        else Task.throw (statusError response)


-- | Idempotent: S3 answers 204 whether or not the object existed; some
-- compatible stores answer 200 or 404 for a missing key.
deleteImpl :: S3Store -> BlobKey -> Task BlobStoreError Unit
deleteImpl store blobKey = do
  response <- sendObject store Delete blobKey Bytes.empty
  let gone = response.statusCode == 204 || response.statusCode == 200 || response.statusCode == 404
  Task.unless gone (Task.throw (statusError response))


-- | 'BlobStore.exists': HEAD; 200 is True, 404 is False, anything else is an error.
existsImpl :: S3Store -> BlobKey -> Task BlobStoreError Bool
existsImpl store blobKey = do
  response <- sendObject store Head blobKey Bytes.empty
  if response.statusCode == 200
    then Task.yield True
    else
      if response.statusCode == 404
        then Task.yield False
        else Task.throw (statusError response)


-- | The HTTP status is the only detail that leaves the backend: S3 error
-- bodies may echo the request, and 403 bodies describe the signature.
statusError :: Response Bytes -> BlobStoreError
statusError response = do
  let status = response.statusCode
  StorageError [fmt|S3 HTTP #{status}|]


-- ==========================================================================
-- Transport
-- ==========================================================================

-- | One signed request against @/bucket/key@. Transport failures (DNS, TLS,
-- timeout, oversized body) become 'StorageError' without the URL.
sendObject :: S3Store -> Method -> BlobKey -> Bytes -> Task BlobStoreError (Response Bytes)
sendObject store method blobKey body = do
  path <- case objectPath store blobKey of
    Err err -> Task.throw err
    Ok validPath -> Task.yield validPath
  now <- DateTime.now
  let request = signedRequest store method path body now
  let send = if store.secure then Http.sendSecure else HttpInternal.sendRaw
  send method request body
    |> Task.mapError transportError


-- | Map a transport failure to 'StorageError' without leaking the signed request.
transportError :: Http.Error -> BlobStoreError
transportError err = case err of
  Http.ResponseTooLarge limit -> StorageError [fmt|S3 response exceeded #{limit} bytes|]
  Http.InvalidUrl _ -> StorageError "S3 endpoint rejected by the HTTP client"
  Http.Error _ -> StorageError "S3 transport failure (write outcome may be unknown)"


-- | Build the request with the SigV4 headers. 'Request' redacts headers in
-- its 'Show' instance, so the Authorization value cannot leak through logs.
signedRequest :: S3Store -> Method -> Text -> Bytes -> DateTime -> Request
signedRequest store method path body now = do
  let payloadHash = SigV4.sha256Hex body
  let headers =
        [ ("host", store.hostHeader)
        , ("x-amz-content-sha256", payloadHash)
        , ("x-amz-date", SigV4.formatAmzDate now)
        ]
  let canonical =
        CanonicalRequest
          { method = Http.methodName method
          , path
          , query = Array.empty
          , headers
          , payloadHash
          }
  let authorization = SigV4.authorizationHeader store.credentials now canonical
  let baseUrl = store.baseUrl
  Http.request
    |> Http.withUrl [fmt|#{baseUrl}#{path}|]
    |> Http.withTimeout 30
    |> withHeaders headers
    |> Http.addHeader "Authorization" authorization
    |> Http.withMaxResponseSize maxObjectBytes


-- | Hard ceiling on one GET body; matches the upload route's default order of
-- magnitude and protects the process from a hostile endpoint.
maxObjectBytes :: Int
maxObjectBytes = 256 * 1024 * 1024


-- | Add every header pair to the request, in order.
withHeaders :: Array (Text, Text) -> Request -> Request
withHeaders headers request =
  headers
    |> Array.foldl (\(name, value) acc -> Http.addHeader name value acc) request


-- | @/bucket/segment/segment@ with every segment URI-encoded. Slashes are
-- kept as separators; dot segments are rejected so an intermediary cannot
-- normalize the path to a different key.
objectPath :: S3Store -> BlobKey -> Result BlobStoreError Text
objectPath store (BlobKey key) = do
  let byteLength = key |> Text.toBytes |> Bytes.length
  let segments = Text.split "/" key
  if byteLength == 0 || byteLength > 1024
    then Err (InvalidBlobKey "S3 key must contain 1 to 1024 UTF-8 bytes")
    else
      if Array.any (\segment -> segment == "." || segment == ".." || Text.isEmpty segment) segments
        then Err (InvalidBlobKey "S3 key must not contain empty or dot path segments")
        else do
          let encoded = segments |> Array.map SigV4.uriEncode |> Text.joinWith "/"
          let bucket = store.bucketName
          Ok [fmt|/#{bucket}/#{encoded}|]
