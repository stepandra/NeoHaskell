# Change 018: Add Integration.Video.ExtractAudio (ffmpeg audio extraction)

Jess wants to transcribe uploaded videos. Upstream already turns audio into
text (`Integration.Audio.Transcribe`, ADR-0041) but cannot read a video file,
and no module calls `ffmpeg`. This change adds the one missing step: an
outbound integration that takes an uploaded video and hands back its audio
track as a mono 16 kHz WAV (`audio/wav`), which `Integration.Audio.Transcribe`
accepts. It mirrors `Integration.Pdf.ExtractText`: a pure request record for
Jess, and a `ToAction` instance in `Internal` that runs a local command-line
tool. Chaining the two integrations (video event → extract audio → upload the
audio → transcribe) is deliberately left to the application; one feature per
change.

```yaml spec
issue: adhoc:video-extract-audio
kind: feature
touches: [outbound-integrations]
breaking: false
new-dependency: false           # ffmpeg is a runtime tool, like pdftotext; no build-depends or flake input
new-capability: false
new-extension-point: false
```

## Contract delta

```diff signatures
+ Integration.Video.ExtractAudio: data Config
+ Integration.Video.ExtractAudio: Config :: Int -> Int -> Int -> Int -> Maybe Text -> Config
+ Integration.Video.ExtractAudio: [timeoutSeconds] :: Config -> Int
+ Integration.Video.ExtractAudio: [sampleRateHz] :: Config -> Int
+ Integration.Video.ExtractAudio: [channels] :: Config -> Int
+ Integration.Video.ExtractAudio: [maxOutputBytes] :: Config -> Int
+ Integration.Video.ExtractAudio: [ffmpegPath] :: Config -> Maybe Text
+ Integration.Video.ExtractAudio: data ExtractionResult
+ Integration.Video.ExtractAudio: ExtractionResult :: Bytes -> Text -> ExtractionResult
+ Integration.Video.ExtractAudio: [audio] :: ExtractionResult -> Bytes
+ Integration.Video.ExtractAudio: [mimeType] :: ExtractionResult -> Text
+ Integration.Video.ExtractAudio: data Request command
+ Integration.Video.ExtractAudio: Request :: FileRef -> Config -> (ExtractionResult -> command) -> (Text -> command) -> Request command
+ Integration.Video.ExtractAudio: [fileRef] :: Request command -> FileRef
+ Integration.Video.ExtractAudio: [config] :: Request command -> Config
+ Integration.Video.ExtractAudio: [onSuccess] :: Request command -> ExtractionResult -> command
+ Integration.Video.ExtractAudio: [onError] :: Request command -> Text -> command
+ Integration.Video.ExtractAudio: defaultConfig :: Config
+ Integration.Video.ExtractAudio.Internal: data Runner
+ Integration.Video.ExtractAudio.Internal: Runner :: (Text -> Task Error (Maybe Text)) -> (Int -> Text -> Array Text -> Path -> Task Error Completion) -> Runner
+ Integration.Video.ExtractAudio.Internal: realRunner :: Runner
+ Integration.Video.ExtractAudio.Internal: [which] :: Runner -> Text -> Task Error (Maybe Text)
+ Integration.Video.ExtractAudio.Internal: [run] :: Runner -> Int -> Text -> Array Text -> Path -> Task Error Completion
+ Integration.Video.ExtractAudio.Internal: resolveFfmpeg :: Runner -> Config -> Task IntegrationError Text
+ Integration.Video.ExtractAudio.Internal: extractAudio :: Runner -> Text -> FileAccessContext -> FileRef -> Config -> Task IntegrationError ExtractionResult
+ Integration.Video.ExtractAudio.Internal: buildFfmpegArgs :: Config -> Path -> Path -> Array Text
+ Integration.Video.ExtractAudio.Internal: executeExtraction :: (ToJSON command, KnownSymbol (NameOf command)) => Runner -> ActionContext -> Request command -> Task IntegrationError (Maybe CommandPayload)
+ Integration.Video.ExtractAudio.Internal: instance (Data.Aeson.Types.ToJSON.ToJSON command, GHC.TypeLits.KnownSymbol (Service.Command.Core.NameOf command)) => Integration.ToAction (Integration.Video.ExtractAudio.Request command)
```

`Config` and `ExtractionResult` derive `Show`, `Eq` and `Generic`. They have no
JSON instances because `Bytes` has none; a command that must carry the audio
converts it in its `onSuccess` callback. `defaultConfig` is 180 s, 16000 Hz,
1 channel, 25 000 000 bytes, `ffmpegPath = Nothing` (look up `ffmpeg` on the
`PATH`). The `Internal` signatures are for tests only; `Runner` is the
process boundary (`which` + `run`), and the `ToAction` instance always uses
`realRunner` (`Subprocess.which` / `Subprocess.runWithTimeout`).

Supporting edits: `integrations/nhintegrations.cabal` (exposed modules, test
module), `.hlint.yaml` (adds `Integration.Video.ExtractAudio.Internal` to the
grandfathered `System.Directory` list, same reason and `belongs-in: Directory`
note as `Integration.Pdf.ExtractText.Internal`: it needs the OS temp
directory), and `docs/changes/test-surfaces.json` (see below).

## Criteria

The integrations hspec suite was not registered in `test-surfaces.json`. This
change registers it as `nhintegrations-test` with root `integrations/test`, so
the locators below resolve.

All criteria are `unit` with boundary `none`: the process boundary is replaced
by a fake `Runner` that never starts a process and, on exit code 0, writes a
fake WAV to the output path it is given. `subprocess:real` is NOT claimed,
because no test runs the real `ffmpeg`. CI and Jess's machines may not have
it, and the argument list and error handling are what this change owns. A real
`ffmpeg` run would need a registered `subprocess:real` fixture. That is a
possible follow-up.

| ID | Behavior | Proving test | Level | Boundary |
|----|----------|--------------|-------|----------|
| C1 | ffmpeg missing: fails with a `ValidationError` that names ffmpeg and says to install it; nothing is run | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#fails with an install hint when ffmpeg is missing` | unit | none |
| C2 | ffmpeg exits non-zero: the message reaches `onError`, and both temp files are removed | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#reports the ffmpeg failure to onError and removes the temp files on a non-zero exit` | unit | none |
| C3 | Success: `onSuccess` gets the WAV bytes written at the output path and `audio/wav`; the temp files are removed; the video was written to the input file before ffmpeg ran | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#returns the WAV bytes and audio/wav on success and removes the temp files`<br>`hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#writes the video to the input file before running ffmpeg` | unit | none |
| C4 | ffmpeg arguments and timeout: defaults give `-vn -ac 1 -ar 16000 -fs 25000000` and 180 s; configured values, and `ffmpegPath`, are honored | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#passes -vn -ac 1 -ar 16000 -fs 25000000 and the default 180 s timeout`<br>`hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#passes the configured timeout, sample rate, channels and size cap`<br>`hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#looks up and runs the configured ffmpegPath` | unit | none |
| C5 | `defaultConfig` is 180 s, 16000 Hz, mono, 25 MB, no explicit path | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#defaults to 180 s, 16000 Hz, mono, 25 MB and ffmpeg from the PATH` | unit | none |
| C6 | File-access failures: uploads disabled fails the action; a missing file reaches `onError` without leaking the file reference | `hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#fails when file uploads are not enabled`<br>`hspec:nhintegrations-test:integrations/test/Integration/Video/ExtractAudioSpec.hs#maps a missing file to a validation error without leaking the file reference` | unit | none |

## User impact

None breaking. Jess gets a new integration, `Integration.Video.ExtractAudio`.
It needs `ffmpeg` on the `PATH` (or `ffmpegPath` set). If `ffmpeg` is missing,
the action fails with a message that tells her to install it. Failures in the
video itself (no audio track, unreadable file, timeout) reach her `onError`
command. Output is capped at 25 MB by default, so a very long video yields
only its first part. To transcribe a video, she chains this integration with
`Integration.Audio.Transcribe` using `mimeType = "audio/wav"`; the module
header shows how. No existing signature changes.

## ADR

Not required — no trigger (breaking / new-dependency / new-capability /
new-extension-point all false). Related context: ADR-0041 (audio
transcription, two-persona model).
