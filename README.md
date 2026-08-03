# MeetingRecorder

MeetingRecorder is a private, Apple-native macOS utility that records audio from one ScreenCaptureKit application together with the Mac's microphone. It does not use a meeting bot, virtual audio device, cloud service, or third-party runtime.

Each session produces two synchronized files:

- `…Google-Meet.m4a`: a normal mixed recording for Finder and QuickTime playback.
- `…Google-Meet.sources.mov`: a two-track, audio-only transcription master. Track 1 is the selected meeting application (“everyone else”); track 2 is the microphone (“you”). A QuickTime container is used because AVFoundation supports multiple independently named AAC tracks there; the normal playback file remains M4A.

ScreenCaptureKit filters audio at application scope. Selecting a Chrome or Safari window records all audio from that browser application, including other tabs and windows.

## Requirements

- Apple Silicon Mac running macOS 15 or later.
- Full Xcode 16 or later on the build Mac. The installed application does not require Xcode.
- A separately granted Microphone and Screen & System Audio Recording permission on every Mac.

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
meeting-recorder status [--json]
meeting-recorder toggle
meeting-recorder config get output-directory
meeting-recorder config set output-directory "~/Another Local Folder"
```

Automatic selection prefers a separately exposed Google Meet/PWA application, then a Meet-looking window's owner, then a single Chrome or Safari candidate. It never falls back to display-wide or all-system audio capture.

## Raycast

Import the scripts under `Raycast/` as Script Commands. They invoke the helper with an absolute path, so Raycast's restricted `PATH` does not matter.

## State and recovery

State and the owner-only control socket live under `~/Library/Application Support/MeetingRecorder/`. Logs live under `~/Library/Logs/MeetingRecorder/`. While recording, both outputs use ten-second fragmented QuickTime containers; after an unexpected process exit the next agent launch attempts to recover playable temporary files. On a normal stop, the one-track mixed file is exported to M4A while the two-track source master remains an audio-only MOV.

The microphone selected at the beginning is pinned for the session. If it disconnects, the recorder finalizes the usable portion instead of silently switching to another microphone. Sleep, source-application termination, SIGINT, and SIGTERM also trigger finalization.

## Privacy and consent

MeetingRecorder itself never uploads recordings or contacts an external service. If you explicitly select an iCloud-backed output directory, macOS may sync those files independently of the recorder.

You are responsible for complying with applicable recording laws, workplace policies, and participant-consent requirements.
