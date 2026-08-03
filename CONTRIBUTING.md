# Contributing to MeetingRecorder

Thanks for helping improve MeetingRecorder. Small, focused changes with a clear macOS use case are easiest to review.

## Before you start

- Search existing issues before proposing a large change.
- Discuss architectural changes before investing in an implementation.
- Use an Apple Silicon Mac with macOS 15+ and Xcode 16+.
- Keep capture and transcription local. Do not introduce an upload, meeting-bot, virtual-device, or telemetry dependency without prior agreement.

## Privacy rules

Never commit or attach real meeting audio, transcripts, debug logs, model caches, signing identities, certificates, or private keys. Create synthetic fixtures when a test needs media. Inspect screenshots and logs for meeting titles, participant information, usernames, and absolute paths before sharing them.

If a vulnerability report contains sensitive information, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development workflow

1. Fork the repository and create a focused branch.
2. Add or update tests for observable behavior.
3. Run the local checks:

   ```sh
   Scripts/test.sh
   Scripts/check-public-repo.sh
   ```

4. Explain the user-visible behavior, testing performed, macOS version, and any permission or signing implications in the pull request.

The test target does not need a signing identity. Building an installable app does:

```sh
Scripts/create-local-signing-certificate.sh
Scripts/build-app.sh
```

## Code style

- Follow the surrounding Swift and shell style.
- Prefer Foundation and Apple frameworks over new dependencies.
- Keep state changes atomic and user files recoverable.
- Treat permission attribution, source scope, and notification visibility as privacy-sensitive behavior.
- Avoid logging transcript text, full window titles, or raw audio.

By submitting a contribution, you agree that it may be distributed under the repository's [MIT License](LICENSE).
