# MeetingRecorder

MeetingRecorder is a private, Apple-native macOS utility that records audio from one ScreenCaptureKit application together with the Mac's microphone. It does not use a meeting bot, virtual audio device, cloud service, or third-party runtime.

Each retained session creates its own timestamped folder under the configured output directory. That folder contains:

- `…Google-Meet.m4a`: a normal mixed recording for Finder and QuickTime playback.
- `…Google-Meet.sources.mov`: a two-track, audio-only transcription master. Track 1 is the selected meeting application (“everyone else”); track 2 is the microphone (“you”). A QuickTime container is used because AVFoundation supports multiple independently named AAC tracks there; the normal playback file remains M4A.
- `transcript.md`: an on-device English/French transcript merged by timestamp. Meeting voices are diarized as `Speaker 1`, `Speaker 2`, and so on; microphone passages are labelled `You`.
- `transcript.raw.md` when debug mode is enabled: Whisper's pre-cleanup segment output. It intentionally retains control and timestamp tokens such as `<|transcribe|>` and does not apply speaker diarization.
- `meeting-recorder.debug.log` when debug mode is enabled: privacy-limited application and CLI diagnostics stored at the recording-folder root.

Recordings shorter than the configured minimum duration (30 seconds by default) are discarded without saving files or their session folder. Longer recordings are saved first, then transcribed in the background. While `status` reports `transcribing`, a new recording cannot begin. If transcription fails, the audio remains safely saved and `status` reports the reason.

MeetingRecorder sends no notifications while capture is starting, recording, or finalizing, so a banner cannot appear in an active screen share. Only after recording has stopped, it maintains one replaceable, silent native notification while transcription is running. It updates at stage changes and approximately every 10%, then is replaced by the normal completion, warning, or failure notification with sound. macOS notifications display textual percentage and stage information rather than a native progress bar. Notification failures include the transcription error. Authorization is requested by `meeting-recorder setup`; if denied, enable MeetingRecorder under System Settings > Notifications.

ScreenCaptureKit filters audio at application scope. Selecting a Chrome or Safari window records all audio from that browser application, including other tabs and windows.

## Requirements

- Apple Silicon Mac running macOS 15 or later.
- Full Xcode 16 or later on the build Mac. The installed application does not require Xcode.
- A separately granted Microphone and Screen & System Audio Recording permission on every Mac.
- Internet access for the first transcription on each Mac, so WhisperKit and SpeakerKit can download their models. Audio is never uploaded.

The default recording directory is the local, configurable `~/Meetings Recordings`. It is intentionally outside Documents and iCloud Drive.

## Build and sign privately

This project uses a local self-signed identity because it is intended for two private Macs and no Apple Developer account is required.

```sh
Scripts/create-local-signing-certificate.sh
Scripts/build-app.sh
Scripts/export-public-certificate.sh
Scripts/install.sh
~/.local/bin/meeting-recorder setup
```

Uninstall the user-scoped app, CLI symlink, and verified Raycast commands with:

```sh
Scripts/uninstall.sh
```

This preserves recordings, configuration, models, logs, permissions, certificates, private keys, and installer backups. Use `Scripts/uninstall.sh --purge-data` to additionally remove configuration, downloaded models, state, and central logs; recordings and recording-folder debug logs are still preserved. The script refuses to uninstall during active recording, finalization, or transcription unless `--force` is explicitly supplied.

Signed builds also copy the same script to `dist/uninstall-meeting-recorder.sh`, next to `MeetingRecorder.app` and the certificate for use on the second Mac.

The certificate-creation step changes the login keychain and may show a macOS authorization prompt. The private key stays in that keychain. Back it up separately as an encrypted `.p12` if future builds may happen on another Mac; do not store the private key in iCloud Drive.

On the second Mac, copy `dist/MeetingRecorder.app` and the exported public certificate, then run:

```sh
Scripts/trust-public-certificate.sh /path/to/MeetingRecorder-Local-Code-Signing.cer
Scripts/install.sh /path/to/MeetingRecorder.app
~/.local/bin/meeting-recorder setup
```

If Gatekeeper asks on the first private installation, open `MeetingRecorder.app` once from Finder using Control-click → Open. Privacy grants are local to each Mac and do not sync through the shared iCloud account.

## Commands

```sh
meeting-recorder setup
meeting-recorder list [--json]
meeting-recorder start [--app NAME | --bundle-id ID | --pid PID]
meeting-recorder stop
meeting-recorder transcribe AUDIO_FILE [--wait] [--json]
meeting-recorder status [--json]
meeting-recorder toggle [--app NAME | --bundle-id ID | --pid PID]
meeting-recorder config list [--json]
meeting-recorder config get KEY [--json]
meeting-recorder config set KEY VALUE [--json]
```

Automatic selection does not select a Chrome-installed Google Meet/PWA application because macOS can expose that visual application while attributing its audio to the main Chrome process. When both exist, it selects main Google Chrome and warns that all Chrome tabs and windows are in scope. Other dedicated meeting applications are preferred, followed by a Meet-looking window's owner and then one unambiguous Chrome or Safari candidate. An explicit `--app`, `--bundle-id`, or `--pid` can still select the Chrome PWA at the risk of a silent application track. Selection never falls back to display-wide or all-system audio capture.

`meeting-recorder transcribe AUDIO_FILE` starts an asynchronous retranscription through the signed agent. Relative paths and `~` are expanded by the CLI. When a recorder-produced M4A has a sibling `*.sources.mov`, the two-track source is selected automatically so `You` remains distinguishable from meeting participants. Follow progress with `status`. Add `--wait` (or its `--sync` alias) to keep the CLI attached until the job succeeds or fails:

```sh
meeting-recorder transcribe ~/Downloads/meeting.m4a --wait
```

Synchronous mode prints percentage and stage updates to standard error, followed by the transcript path, detected language or languages, and generic participant identities such as `You`, `Speaker 1`, and `Speaker 2`. With `--json`, progress remains on standard error and the final structured response is written to standard output. The same progress, detected-language codes, and participant labels are available in `meeting-recorder status --json` under `state.transcriptionProgress`.

During and after transcription, the regular human-readable `meeting-recorder status` output includes separate `Progress`, `Stage`, `Detected languages`, and `Participants` lines. The final completed or failed progress summary remains available until another recording or transcription starts.

A recorder `*.sources.mov` replaces `transcript.md` in its session folder. The normal transcript preserves `You` versus meeting speakers and removes Whisper control tokens. With `debug true`, `transcript.raw.md` additionally preserves those tokens and original track labels for troubleshooting. An ordinary one-track file writes `BASENAME.transcript.md`, plus `BASENAME.transcript.raw.md` only in debug mode, beside the input and assigns generic speaker labels because no separate microphone track exists. Existing transcript output is replaced atomically. Completion and failure use the same native notifications as automatic post-recording transcription.

## Configuration

Configuration is validated and stored atomically in `~/Library/Application Support/MeetingRecorder/config.json`. Use `config list` to see the effective values. Supported keys are:

| Key | Values | Default |
|---|---|---|
| `output-directory` | Writable local or protected path | `~/Meetings Recordings` |
| `transcription-model` | Nonempty WhisperKit model identifier | `large-v3-v20240930_626MB` |
| `minimum-duration` | Nonnegative seconds; `0` keeps every recording | `30` |
| `language` | `auto`, `en`, or `fr` | `auto` |
| `diarization` | `true` or `false` | `true` |
| `speaker-count` | `auto` or an integer from 1 through 20 | `auto` |
| `debug` | `true` or `false` | `false` |

For example:

```sh
meeting-recorder config set minimum-duration 10
meeting-recorder config set language auto
meeting-recorder config set speaker-count 3
meeting-recorder config set diarization false
meeting-recorder config set debug true
```

`language auto` supports bilingual English/French recordings; forcing `en` or `fr` is useful when automatic detection is unreliable. `speaker-count` is a hint to SpeakerKit and is ignored when diarization is disabled. `debug true` retains the raw Whisper transcript and a session log containing source identity, capture levels and counters, chunk timing/energy/language results, diarization status, file lifecycle, errors, and CLI outcomes. It intentionally excludes transcript text and meeting/window titles. Debug mode is captured when recording or manual transcription starts; transcription settings are captured when recording finishes or manual transcription starts. Changing them does not alter work already in progress.

## Raycast

Import the scripts under `Raycast/` as Script Commands. They invoke the helper with an absolute path, so Raycast's restricted `PATH` does not matter.

## State and recovery

State and the owner-only control socket live under `~/Library/Application Support/MeetingRecorder/`. The always-on rotating operational log lives under `~/Library/Logs/MeetingRecorder/`; debug mode additionally copies privacy-limited session diagnostics to `meeting-recorder.debug.log` in the recording folder. While recording, both outputs use ten-second fragmented QuickTime containers; after an unexpected process exit the next agent launch attempts to recover playable temporary files. On a normal stop, the one-track mixed file is exported to M4A while the two-track source master remains an audio-only MOV.

Transcription uses Argmax's `WhisperKit` package and the multilingual `large-v3-v20240930_626MB` model with automatic language detection enabled for each one-minute chunk. Chunks are decoded sequentially so an individual inference failure aborts with a visible error instead of silently dropping part of the transcript. English and French can appear in the same recording. The two source tracks are transcribed separately and merged chronologically. Generated word and segment timestamps are constrained to the media duration; audible one-minute ranges that return no transcript text are listed as warnings for review.

Argmax `SpeakerKit` diarizes the complete meeting track with Pyannote so its generic `Speaker 1`, `Speaker 2`, etc. labels remain stable throughout one recording. It identifies recurring voices, not people's real names; assigning names would require a separate enrollment or editing workflow. The microphone track always remains `You`. If the recorded application track is effectively silent, diarization is skipped, only microphone speech is labelled `You`, and a warning is reported after recording has ended. If diarization otherwise fails, the transcript is still saved with remote passages labelled `Meeting`, and `status` reports a warning.

Models are downloaded once and retained under `~/Library/Application Support/MeetingRecorder/Models/`; subsequent processing is local. The first transcription takes longer while both model sets download and initialize. Stable whole-meeting diarization also holds the 16 kHz meeting track in memory (about 230 MB per recorded hour, in addition to model memory).

The app icon is generated during the signed build from `icone.png` at the repository root and embedded as `MeetingRecorder.icns` for Finder and native notifications.

The microphone selected at the beginning is pinned for the session. If it disconnects, the recorder finalizes the usable portion instead of silently switching to another microphone. Sleep, source-application termination, SIGINT, and SIGTERM also trigger finalization.

## Privacy and consent

MeetingRecorder never uploads recordings or transcript audio. WhisperKit and SpeakerKit contact their model host only to download missing speech models. If you explicitly select an iCloud-backed output directory, macOS may sync recordings and transcripts independently of the recorder.

You are responsible for complying with applicable recording laws, workplace policies, and participant-consent requirements.
