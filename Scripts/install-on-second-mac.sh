#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_app="$script_dir/MeetingRecorder.app"
certificate="$script_dir/MeetingRecorder-Local-Code-Signing.cer"
raycast_source="$script_dir/meeting-recorder-toggle.sh"
destination_dir="$HOME/Applications"
destination="$destination_dir/MeetingRecorder.app"
cli_dir="$HOME/.local/bin"
cli="$cli_dir/meeting-recorder"
raycast_dir="$HOME/raycast-scripts"
raycast_destination="$raycast_dir/meeting-recorder-toggle.sh"

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  print -u2 "MeetingRecorder requires an Apple Silicon Mac."
  exit 1
fi

macos_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if (( macos_major < 15 )); then
  print -u2 "MeetingRecorder requires macOS 15 or later."
  exit 1
fi

if [[ ! -d "$source_app" ]]; then
  print -u2 "Missing app next to this script: $source_app"
  exit 1
fi
if [[ ! -f "$certificate" ]]; then
  print -u2 "Missing certificate next to this script: $certificate"
  exit 1
fi
if [[ ! -f "$raycast_source" ]]; then
  print -u2 "Missing Raycast script next to this installer: $raycast_source"
  exit 1
fi

print "Trusting the MeetingRecorder public signing certificate..."
/usr/bin/security add-trusted-cert -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$certificate"

/bin/mkdir -p "$destination_dir" "$cli_dir" "$raycast_dir"
if [[ -e "$destination" ]]; then
  backup="$destination_dir/MeetingRecorder.app.backup.$(/bin/date +%Y%m%d%H%M%S)"
  /bin/mv "$destination" "$backup"
  print "Previous installation moved to $backup"
fi

/usr/bin/ditto "$source_app" "$destination"
/bin/ln -sfn "$destination/Contents/Helpers/meeting-recorder" "$cli"
/bin/cp "$raycast_source" "$raycast_destination"
/bin/chmod 755 "$raycast_destination"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"

print "Installed $destination"
print "CLI: $cli"
print "Raycast command: $raycast_destination"
print "Running permission setup..."
if ! "$cli" setup; then
  print -u2 "Setup did not complete. If Gatekeeper blocked the first launch,"
  print -u2 "Control-click MeetingRecorder.app in ~/Applications, choose Open,"
  print -u2 "then run: $cli setup"
  exit 1
fi

print "MeetingRecorder is ready. Test it with: $cli list"
