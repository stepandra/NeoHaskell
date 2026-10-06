---
group: platform
component: Integrations
impact: compatible
category: Added
---

## Summary

You can now pull the audio out of an uploaded video with the new
`Integration.Video.ExtractAudio` integration. Give it the video's file
reference and it returns the audio as a mono 16 kHz WAV (`audio/wav`), ready
to pass to `Integration.Audio.Transcribe` with `mimeType = "audio/wav"`. By
default it allows 180 seconds and stops at 25 MB; both limits are in the
config. It needs `ffmpeg` on the machine that runs your app (for example
`brew install ffmpeg`). If `ffmpeg` is missing, the action fails with a
message that tells you to install it. If the video itself cannot be
converted, your `onError` command receives the reason.

Existing applications do not need any changes. To verify locally, run
`./dev test 'Integration.Video' nhintegrations-test` and confirm the
extraction examples pass. They use a stand-in for `ffmpeg`, so you do not
need it installed to run them.
