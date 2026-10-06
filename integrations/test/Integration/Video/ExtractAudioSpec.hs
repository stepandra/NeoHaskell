module Integration.Video.ExtractAudioSpec (spec) where

import Array (Array)
import Array qualified
import Auth.SecretStore.InMemory qualified as InMemorySecretStore
import Basics
import ConcurrentMap (ConcurrentMap)
import ConcurrentMap qualified
import File qualified
import Integration (ActionContext (..), CommandPayload (..))
import Integration (FileAccessContext (..))
import Integration qualified
import Integration.Video.ExtractAudio (Config (..), ExtractionResult (..), Request (..))
import Integration.Video.ExtractAudio qualified as VideoAudio
import Integration.Video.ExtractAudio.Internal (Runner (..), executeExtraction)
import Json qualified
import Lock (Lock)
import Map qualified
import Maybe (Maybe (..))
import Path qualified
import Result (Result (..))
import Service.Command.Core (NameOf)
import Service.FileUpload.Core (FileAccessError (..), FileRef (..))
import Service.Integration.DispatchRegistry qualified as DispatchRegistry
import Subprocess qualified
import Task (Task)
import Task qualified
import Test.Hspec
import Text (Text)
import Text qualified
import Var (Var)
import Var qualified


spec :: Spec
spec = do
  describe "Integration.Video.ExtractAudio.defaultConfig" do
    it "defaults to 180 s, 16000 Hz, mono, 25 MB and ffmpeg from the PATH" do
      VideoAudio.defaultConfig `shouldBe` Config
        { timeoutSeconds = 180
        , sampleRateHz = 16000
        , channels = 1
        , maxOutputBytes = 25000000
        , ffmpegPath = Nothing
        }

  describe "Integration.Video.ExtractAudio.executeExtraction" do
    it "fails with an install hint when ffmpeg is missing" do
      (outcome, calls) <- Task.runOrPanic (runScenario missingFfmpeg VideoAudio.defaultConfig)
      case outcome of
        Err (Integration.ValidationError message) -> do
          Text.contains "ffmpeg" message `shouldBe` True
          Text.contains "install" message `shouldBe` True
        Err other ->
          expectationFailure [fmt|expected a ValidationError, got #{other}|]
        Ok _ ->
          expectationFailure "expected an error when ffmpeg is missing"
      Array.length calls `shouldBe` 0

    it "reports the ffmpeg failure to onError and removes the temp files on a non-zero exit" do
      (outcome, calls) <- Task.runOrPanic (runScenario (failingFfmpeg "Invalid data found") VideoAudio.defaultConfig)
      case outcome of
        Ok (Just payload) -> do
          let encoded = Json.encodeText payload.commandData
          Text.contains "ExtractionFailed" encoded `shouldBe` True
          Text.contains "Invalid data found" encoded `shouldBe` True
        _ ->
          expectationFailure "expected the onError command"
      Array.length calls `shouldBe` 1
      Task.runOrPanic (anyTempFileLeft calls) `shouldReturn` False

    it "returns the WAV bytes and audio/wav on success and removes the temp files" do
      (outcome, calls) <- Task.runOrPanic (runScenario succeedingFfmpeg VideoAudio.defaultConfig)
      case outcome of
        Ok (Just payload) -> do
          let encoded = Json.encodeText payload.commandData
          Text.contains "AudioExtracted" encoded `shouldBe` True
          Text.contains fakeWavText encoded `shouldBe` True
          Text.contains "audio/wav" encoded `shouldBe` True
        _ ->
          expectationFailure "expected the onSuccess command"
      Array.length calls `shouldBe` 1
      Task.runOrPanic (anyTempFileLeft calls) `shouldReturn` False

    it "writes the video to the input file before running ffmpeg" do
      (_, calls) <- Task.runOrPanic (runScenario succeedingFfmpeg VideoAudio.defaultConfig)
      let inputPresent = calls |> Array.map (\call -> call.callInputPresent)
      inputPresent `shouldBe` Array.wrap True

    it "passes -vn -ac 1 -ar 16000 -fs 25000000 and the default 180 s timeout" do
      (_, calls) <- Task.runOrPanic (runScenario succeedingFfmpeg VideoAudio.defaultConfig)
      case Array.get 0 calls of
        Nothing -> expectationFailure "expected one ffmpeg call"
        Just call -> do
          let joined = Text.joinWith " " call.callArguments
          Text.contains "-vn -ac 1 -ar 16000 -fs 25000000" joined `shouldBe` True
          Text.contains "-nostdin" joined `shouldBe` True
          call.callTimeout `shouldBe` 180
          call.callExecutable `shouldBe` "/usr/bin/ffmpeg"

    it "passes the configured timeout, sample rate, channels and size cap" do
      let custom = VideoAudio.defaultConfig
            { timeoutSeconds = 42
            , sampleRateHz = 8000
            , channels = 2
            , maxOutputBytes = 1000
            }
      (_, calls) <- Task.runOrPanic (runScenario succeedingFfmpeg custom)
      case Array.get 0 calls of
        Nothing -> expectationFailure "expected one ffmpeg call"
        Just call -> do
          let joined = Text.joinWith " " call.callArguments
          Text.contains "-vn -ac 2 -ar 8000 -fs 1000" joined `shouldBe` True
          call.callTimeout `shouldBe` 42

    it "looks up and runs the configured ffmpegPath" do
      let custom = VideoAudio.defaultConfig {ffmpegPath = Just "/opt/ffmpeg/bin/ffmpeg"}
      (_, calls) <- Task.runOrPanic (runScenario succeedingFfmpeg custom)
      case Array.get 0 calls of
        Nothing -> expectationFailure "expected one ffmpeg call"
        Just call ->
          call.callExecutable `shouldBe` "/opt/ffmpeg/bin/ffmpeg"

    it "fails when file uploads are not enabled" do
      callsVar <- Task.runOrPanic (textTask (Var.new Array.empty))
      let runner = fakeRunner callsVar succeedingFfmpeg
      ctx <- Task.runOrPanic (makeContext Nothing)
      outcome <- Task.runOrPanic (textTask (executeExtraction runner ctx (makeRequest VideoAudio.defaultConfig) |> Task.asResult))
      case outcome of
        Err (Integration.ValidationError message) ->
          Text.contains "File uploads not enabled" message `shouldBe` True
        _ ->
          expectationFailure "expected a ValidationError for disabled file uploads"

    it "maps a missing file to a validation error without leaking the file reference" do
      callsVar <- Task.runOrPanic (textTask (Var.new Array.empty))
      let runner = fakeRunner callsVar succeedingFfmpeg
      let missingFile = FileAccessContext
            { retrieveFile = \ref -> Task.throw (FileNotFound ref)
            , getFileMetadata = \ref -> Task.throw (FileNotFound ref)
            }
      ctx <- Task.runOrPanic (makeContext (Just missingFile))
      outcome <- Task.runOrPanic (textTask (executeExtraction runner ctx (makeRequest VideoAudio.defaultConfig) |> Task.asResult))
      case outcome of
        Ok (Just payload) -> do
          let encoded = Json.encodeText payload.commandData
          Text.contains "ExtractionFailed" encoded `shouldBe` True
          Text.contains "File not found" encoded `shouldBe` True
          Text.contains "00000000-0000-0000-0000-000000000001" encoded `shouldBe` False
        _ ->
          expectationFailure "expected the onError command"
      calls <- Task.runOrPanic (textTask (Var.get callsVar))
      Array.length calls `shouldBe` 0


-- | How the fake ffmpeg behaves.
data Scenario = Scenario
  { ffmpegInstalled :: Bool
  , ffmpegExitCode :: Int
  , ffmpegStderr :: Text
  }


-- | One recorded invocation of the fake runner.
data Call = Call
  { callTimeout :: Int
  , callExecutable :: Text
  , callArguments :: Array Text
  , callInputPresent :: Bool
  }
  deriving (Eq, Show)


missingFfmpeg :: Scenario
missingFfmpeg = Scenario {ffmpegInstalled = False, ffmpegExitCode = 0, ffmpegStderr = ""}


failingFfmpeg :: Text -> Scenario
failingFfmpeg stderrText = Scenario {ffmpegInstalled = True, ffmpegExitCode = 1, ffmpegStderr = stderrText}


succeedingFfmpeg :: Scenario
succeedingFfmpeg = Scenario {ffmpegInstalled = True, ffmpegExitCode = 0, ffmpegStderr = ""}


fakeWavText :: Text
fakeWavText = "RIFF-fake-wav"


-- | A runner that never starts a process. On exit code 0 it writes
-- 'fakeWavText' to the output path it was given, like ffmpeg would.
fakeRunner :: Var (Array Call) -> Scenario -> Runner
fakeRunner callsVar scenario = Runner
  { which = \name ->
      if not scenario.ffmpegInstalled
        then Task.yield Nothing
        else if Text.startsWith "/" name
          then Task.yield (Just name)
          else Task.yield (Just [fmt|/usr/bin/#{name}|])
  , run = \timeout executable arguments _ -> do
      inputPresent <- case Array.get 4 arguments |> andThenPath of
        Nothing -> Task.yield False
        Just inputPath ->
          File.exists inputPath
            |> Task.mapError (\_ -> Subprocess.ProcessError "fake exists check failed")
      let call = Call
            { callTimeout = timeout
            , callExecutable = executable
            , callArguments = arguments
            , callInputPresent = inputPresent
            }
      recorded <- Var.get callsVar
      Var.set (Array.push call recorded) callsVar
      Task.when (scenario.ffmpegExitCode == 0) do
        case Array.last arguments |> andThenPath of
          Nothing -> Task.throw (Subprocess.ProcessError "fake runner: no output path")
          Just outputPath ->
            File.writeBytes outputPath (Text.toBytes fakeWavText)
              |> Task.mapError (\_ -> Subprocess.ProcessError "fake runner: write failed")
      Task.yield Subprocess.Completion
        { exitCode = scenario.ffmpegExitCode
        , stdout = ""
        , stderr = scenario.ffmpegStderr
        }
  }


andThenPath :: Maybe Text -> Maybe Path.Path
andThenPath maybeText = case maybeText of
  Nothing -> Nothing
  Just text -> Path.fromText text


-- | The input and output temp paths ffmpeg was given.
tempPathsOf :: Call -> Array Path.Path
tempPathsOf call = do
  let inputPath = Array.get 4 call.callArguments |> andThenPath
  let outputPath = Array.last call.callArguments |> andThenPath
  case (inputPath, outputPath) of
    (Just input, Just output) -> Array.fromLinkedList [input, output]
    _ -> Array.empty


-- | Pins the error type of a helper task to 'Text' so 'Task.runOrPanic' can show it.
textTask :: Task Text value -> Task Text value
textTask task = task


anyTempFileLeft :: Array Call -> Task Text Bool
anyTempFileLeft calls = do
  flags <- calls
    |> Array.flatMap tempPathsOf
    |> Task.mapArray (\path -> File.exists path |> Task.recover (\_ -> Task.yield False))
  Task.yield (Array.any (\present -> present) flags)


makeContext :: Maybe Integration.FileAccessContext -> Task Text ActionContext
makeContext fileAccess = do
  stubStore <- InMemorySecretStore.new
  emptyLocks <- ConcurrentMap.new :: Task Text (ConcurrentMap Text Lock)
  Task.yield ActionContext
    { secretStore = stubStore
    , providerRegistry = Integration.fromMap Map.empty
    , refreshLocks = emptyLocks
    , fileAccess = fileAccess
    , outboundDispatch = DispatchRegistry.empty
    }


runScenario ::
  Scenario ->
  Config ->
  Task Text (Result Integration.IntegrationError (Maybe CommandPayload), Array Call)
runScenario scenario config = do
  callsVar <- Var.new Array.empty
  let runner = fakeRunner callsVar scenario
  let videoAccess = FileAccessContext
        { retrieveFile = \_ -> Task.yield (Text.toBytes "fake video bytes")
        , getFileMetadata = \_ -> Task.throw (StorageError "metadata not available")
        }
  ctx <- makeContext (Just videoAccess)
  outcome <- executeExtraction runner ctx (makeRequest config) |> Task.asResult
  calls <- Var.get callsVar
  Task.yield (outcome, calls)


makeRequest :: Config -> Request TestCommand
makeRequest config = Request
  { fileRef = FileRef "00000000-0000-0000-0000-000000000001"
  , config = config
  , onSuccess = \result -> AudioExtracted
      { audioText = Text.fromBytes result.audio
      , mime = result.mimeType
      }
  , onError = \reason -> ExtractionFailed {reason}
  }


-- | Minimal command type satisfying the ToAction constraints.
data TestCommand
  = AudioExtracted {audioText :: Text, mime :: Text}
  | ExtractionFailed {reason :: Text}
  deriving (Eq, Show, Generic)


instance Json.ToJSON TestCommand


type instance NameOf TestCommand = "TestCommand"
