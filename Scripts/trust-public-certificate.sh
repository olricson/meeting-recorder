#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: $0 /path/to/MeetingRecorder-Local-Code-Signing.cer"
  exit 2
fi
/usr/bin/security add-trusted-cert -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" "$1"
print "Trusted the MeetingRecorder signing certificate for this user."
