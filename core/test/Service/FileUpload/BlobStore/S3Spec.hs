module Service.FileUpload.BlobStore.S3Spec where

import Array qualified
import Bytes qualified
import ConcurrentVar qualified
import Core
import Result qualified
import Service.FileUpload.BlobStore (BlobStore (..), BlobStoreError (..))
import Service.FileUpload.BlobStore.S3 (S3Config (..), createBlobStore)
import Service.FileUpload.BlobStore.S3.FakeS3 (FakeS3 (..), Mode (..), withFakeS3)
import Service.FileUpload.BlobStore.S3.FakeS3 qualified as FakeS3
import Service.FileUpload.Core (BlobKey (..))
import Task qualified
import Test
import Text qualified


spec :: Spec Unit
spec = do
  describe "Service.FileUpload.BlobStore.S3" do
    describe "Basic Operations" do
      it "store and retrieve roundtrips bytes through signed PUT and GET" \_ -> do
        withS3BlobStore \fake blobStore -> do
          let blobKey = BlobKey "test-blob-1"
          let content = "Hello, S3!" |> Text.toBytes
          blobStore.store blobKey content |> orFail
          retrieved <- blobStore.retrieve blobKey |> orFail
          retrieved |> shouldBe content
          seen <- ConcurrentVar.peek fake.requests
          seen |> shouldBe [("PUT", "/test-bucket/test-blob-1"), ("GET", "/test-bucket/test-blob-1")]

      it "store overwrites an existing blob" \_ -> do
        withS3BlobStore \_ blobStore -> do
          let blobKey = BlobKey "overwrite-me"
          blobStore.store blobKey ("first" |> Text.toBytes) |> orFail
          blobStore.store blobKey ("second" |> Text.toBytes) |> orFail
          retrieved <- blobStore.retrieve blobKey |> orFail
          retrieved |> shouldBe ("second" |> Text.toBytes)

      it "exists answers True after store and False for an unknown key" \_ -> do
        withS3BlobStore \fake blobStore -> do
          let blobKey = BlobKey "present"
          blobStore.store blobKey ("x" |> Text.toBytes) |> orFail
          present <- blobStore.exists blobKey |> orFail
          present |> shouldBe True
          missing <- blobStore.exists (BlobKey "absent") |> orFail
          missing |> shouldBe False
          seen <- ConcurrentVar.peek fake.requests
          seen |> Array.get 1 |> shouldBe (Just ("HEAD", "/test-bucket/present"))

      it "delete removes the blob and is idempotent" \_ -> do
        withS3BlobStore \fake blobStore -> do
          let blobKey = BlobKey "delete-me"
          blobStore.store blobKey ("bye" |> Text.toBytes) |> orFail
          blobStore.delete blobKey |> orFail
          blobStore.delete blobKey |> orFail
          remaining <- FakeS3.objects fake
          remaining |> shouldBe []

      it "stores and retrieves an empty blob" \_ -> do
        withS3BlobStore \_ blobStore -> do
          let blobKey = BlobKey "empty"
          blobStore.store blobKey Bytes.empty |> orFail
          retrieved <- blobStore.retrieve blobKey |> orFail
          retrieved |> shouldBe Bytes.empty

    describe "Error Mapping" do
      it "retrieve of a missing key is NotFound" \_ -> do
        withS3BlobStore \_ blobStore -> do
          result <- blobStore.retrieve (BlobKey "nope") |> Task.asResult
          result |> shouldBe (Err (NotFound (BlobKey "nope")))

      it "a 403 from the store is a StorageError carrying only the status" \_ -> do
        withS3BlobStore \fake blobStore -> do
          ConcurrentVar.swap Forbid fake.mode |> discard
          result <- blobStore.store (BlobKey "denied") ("x" |> Text.toBytes) |> Task.asResult
          result |> shouldBe (Err (StorageError "S3 HTTP 403"))
          existsResult <- blobStore.exists (BlobKey "denied") |> Task.asResult
          existsResult |> shouldBe (Err (StorageError "S3 HTTP 403"))

      it "an unreachable endpoint is a StorageError without the URL" \_ -> do
        blobStore <-
          createBlobStore (validConfig "http://127.0.0.1:9")
            |> Task.mapError (\e -> [fmt|createBlobStore failed: #{e}|])
        result <- blobStore.exists (BlobKey "any") |> Task.asResult
        case result of
          Err (StorageError message) -> Text.contains "127.0.0.1" message |> shouldBe False
          other -> fail [fmt|expected StorageError, got #{show other}|]

    describe "Key Validation" do
      it "encodes each key segment and keeps slashes as separators" \_ -> do
        withS3BlobStore \fake blobStore -> do
          blobStore.store (BlobKey "owner/a b$c") ("x" |> Text.toBytes) |> orFail
          seen <- ConcurrentVar.peek fake.requests
          seen |> shouldBe [("PUT", "/test-bucket/owner/a%20b%24c")]

      it "rejects dot segments and empty keys without sending a request" \_ -> do
        withS3BlobStore \fake blobStore -> do
          dotResult <- blobStore.store (BlobKey "a/../b") Bytes.empty |> Task.asResult
          dotResult |> shouldBe (Err (InvalidBlobKey "S3 key must not contain empty or dot path segments"))
          emptyResult <- blobStore.exists (BlobKey "") |> Task.asResult
          emptyResult |> shouldBe (Err (InvalidBlobKey "S3 key must contain 1 to 1024 UTF-8 bytes"))
          seen <- ConcurrentVar.peek fake.requests
          seen |> shouldBe []

    describe "Configuration" do
      it "rejects an http endpoint that is not loopback" \_ -> do
        result <- createBlobStore (validConfig "http://s3.example.com") |> Task.asResult
        result |> Result.map (\_ -> ()) |> shouldBe (Err "S3 requires HTTPS outside literal loopback")

      it "rejects an endpoint carrying a path, query or credentials" \_ -> do
        withPath <- createBlobStore (validConfig "https://s3.example.com/bucket") |> Task.asResult
        withPath |> Result.map (\_ -> ()) |> shouldBe (Err "S3 endpoint must not contain credentials, path, query or fragment")
        withUser <- createBlobStore (validConfig "https://user:pw@s3.example.com") |> Task.asResult
        withUser |> Result.map (\_ -> ()) |> shouldBe (Err "S3 endpoint must not contain credentials, path, query or fragment")

      it "rejects empty fields and non-DNS bucket names" \_ -> do
        emptyKey <- createBlobStore (configWith "" "test-bucket") |> Task.asResult
        emptyKey |> Result.map (\_ -> ()) |> shouldBe (Err "S3 configuration fields must not be empty")
        badBucket <- createBlobStore (configWith "AKIAIOSFODNN7EXAMPLE" "Bad_Bucket") |> Task.asResult
        badBucket |> Result.map (\_ -> ()) |> shouldBe (Err "S3 bucket must be a DNS-style bucket name")

      it "accepts an https endpoint without contacting it" \_ -> do
        result <- createBlobStore (validConfig "https://s3.example.com") |> Task.asResult
        result |> Result.map (\_ -> ()) |> shouldBe (Ok ())

      it "accepts loopback over plain http, including bracketed IPv6" \_ -> do
        ipv4 <- createBlobStore (validConfig "http://127.0.0.1:9000/") |> Task.asResult
        ipv4 |> Result.map (\_ -> ()) |> shouldBe (Ok ())
        ipv6 <- createBlobStore (validConfig "http://[::1]:9000") |> Task.asResult
        ipv6 |> Result.map (\_ -> ()) |> shouldBe (Ok ())


-- ==========================================================================
-- Test Infrastructure
-- ==========================================================================

validConfig :: Text -> S3Config
validConfig endpoint =
  S3Config
    { endpoint
    , bucket = "test-bucket"
    , region = "us-east-1"
    , accessKeyId = "AKIAIOSFODNN7EXAMPLE"
    , secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }


configWith :: Text -> Text -> S3Config
configWith accessKeyId bucket =
  S3Config
    { endpoint = "https://s3.example.com"
    , bucket
    , region = "us-east-1"
    , accessKeyId
    , secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }


withS3BlobStore :: (FakeS3 -> BlobStore -> Task Text Unit) -> Task Text Unit
withS3BlobStore action =
  withFakeS3 "test-bucket" "AKIAIOSFODNN7EXAMPLE" \fake -> do
    blobStore <-
      createBlobStore (validConfig fake.endpoint)
        |> Task.mapError (\e -> [fmt|createBlobStore failed: #{e}|])
    action fake blobStore


orFail :: Task BlobStoreError value -> Task Text value
orFail task = task |> Task.mapError (\e -> [fmt|blob store failed: #{show e}|])
