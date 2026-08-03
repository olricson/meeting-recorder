# Security policy

## Supported versions

MeetingRecorder is an early source-first project without published binary releases. Security fixes target the latest `main` branch only.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature when it is available for this repository. If it is not enabled, open a minimal issue asking the maintainer for a private reporting channel; do not include exploit details or sensitive files in that issue.

Include the affected commit, macOS version, impact, reproduction conditions, and a suggested mitigation when possible. Allow reasonable time for investigation before public disclosure.

Never send a real recording, transcript, debug log, model cache, signing identity, certificate, or private key. Reproduce with synthetic media and redact usernames, local paths, meeting titles, bundle identities that reveal private software, and participant information.

## Security boundaries

MeetingRecorder intentionally runs as the current user and uses local files plus an owner-only Unix socket. It is not a sandboxed Mac App Store application and its private self-signed builds are not notarized. Reports concerning unauthorized capture, permission attribution, control-socket access, unsafe file handling, secret exposure, or unexpected network transfer are especially useful.
