# MeetingRecorder

MeetingRecorder is a private, Apple-native macOS utility that records audio from one ScreenCaptureKit application together with the Mac's microphone. It does not use a meeting bot, virtual audio device, cloud service, or third-party runtime.

Each retained session creates its own timestamped folder under the configured output directory. That folder contains:

- `…Google-Meet.m4a`: a normal mixed recording for Finder and QuickTime playback.
- `…Google-Meet.sources.mov`: a two-track, audio-only transcription master. Track 1 is the selected meeting application (“everyone else”); track 2 is the microphone (“you”). A QuickTime container is used because AVFoundation supports multiple independently named AAC tracks there; the normal playback file remains M4A.
- `transcript.md`: an on-device English/French transcript merged by timestamp. Meeting voices are diarized as `Speaker 1`, `Speaker 2`, and so on; microphone passages are labelled `You`.

Recordings shorter than the configured minimum duration (30 seconds by default) are discarded without saving files or their session folder. Longer recordings are saved first, then transcribed in the background. While `status` reports `transcribing`, a new recording cannot begin. If transcription fails, the audio remains safely saved and `status` reports the reason.

MeetingRecorder sends a native notification when transcription completes, completes with a speaker-identification warning, or fails. Notification failures include the transcription error. Authorization is requested by `meeting-recorder setup`; if denied, enable MeetingRecorder under System Settings > Notifications.

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
meeting-recorder transcribe AUDIO_FILE [--json]
meeting-recorder status [--json]
meeting-recorder toggle [--app NAME | --bundle-id ID | --pid PID]
meeting-recorder config list [--json]
meeting-recorder config get KEY [--json]
meeting-recorder config set KEY VALUE [--json]
```

Automatic selection prefers a separately exposed Google Meet/PWA application, then a Meet-looking window's owner, then a single Chrome or Safari candidate. It never falls back to display-wide or all-system audio capture.

`meeting-recorder transcribe AUDIO_FILE` starts an asynchronous retranscription through the signed agent. Relative paths and `~` are expanded by the CLI; follow progress with `status`. A recorder `*.sources.mov` replaces `transcript.md` in its session folder and preserves `You` versus meeting speakers. An ordinary one-track file writes `BASENAME.transcript.md` beside the input and assigns generic speaker labels because no separate microphone track exists. Existing transcript output is replaced atomically. Completion and failure use the same native notifications as automatic post-recording transcription.

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

For example:

```sh
meeting-recorder config set minimum-duration 10
meeting-recorder config set language auto
meeting-recorder config set speaker-count 3
meeting-recorder config set diarization false
```

`language auto` supports bilingual English/French recordings; forcing `en` or `fr` is useful when automatic detection is unreliable. `speaker-count` is a hint to SpeakerKit and is ignored when diarization is disabled. Settings are captured when a recording finishes or a manual transcription starts; changing them does not alter a transcription already in progress.

## Raycast

Import the scripts under `Raycast/` as Script Commands. They invoke the helper with an absolute path, so Raycast's restricted `PATH` does not matter.

## State and recovery

State and the owner-only control socket live under `~/Library/Application Support/MeetingRecorder/`. Logs live under `~/Library/Logs/MeetingRecorder/`. While recording, both outputs use ten-second fragmented QuickTime containers; after an unexpected process exit the next agent launch attempts to recover playable temporary files. On a normal stop, the one-track mixed file is exported to M4A while the two-track source master remains an audio-only MOV.

Transcription uses Argmax's `WhisperKit` package and the multilingual `large-v3-v20240930_626MB` model with automatic language detection enabled for every ten-minute chunk. English and French can therefore appear in the same recording. The two source tracks are transcribed separately and merged chronologically.

Argmax `SpeakerKit` diarizes the complete meeting track with Pyannote so its generic `Speaker 1`, `Speaker 2`, etc. labels remain stable throughout one recording. It identifies recurring voices, not people's real names; assigning names would require a separate enrollment or editing workflow. The microphone track always remains `You`. If diarization fails, the transcript is still saved with remote passages labelled `Meeting`, and `status` reports a warning.

Models are downloaded once and retained under `~/Library/Application Support/MeetingRecorder/Models/`; subsequent processing is local. The first transcription takes longer while both model sets download and initialize. Stable whole-meeting diarization also holds the 16 kHz meeting track in memory (about 230 MB per recorded hour, in addition to model memory).

The app icon is generated during the signed build from `icone.png` at the repository root and embedded as `MeetingRecorder.icns` for Finder and native notifications.

The microphone selected at the beginning is pinned for the session. If it disconnects, the recorder finalizes the usable portion instead of silently switching to another microphone. Sleep, source-application termination, SIGINT, and SIGTERM also trigger finalization.

## Privacy and consent

MeetingRecorder never uploads recordings or transcript audio. WhisperKit and SpeakerKit contact their model host only to download missing speech models. If you explicitly select an iCloud-backed output directory, macOS may sync recordings and transcripts independently of the recorder.

You are responsible for complying with applicable recording laws, workplace policies, and participant-consent requirements.
