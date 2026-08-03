#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
source_app="${1:-$repo_dir/dist/MeetingRecorder.app}"
destination_dir="$HOME/Applications"
destination="$destination_dir/MeetingRecorder.app"
cli_dir="$HOME/.local/bin"

if [[ ! -d "$source_app" ]]; then
  print -u2 "App bundle not found: $source_app"
  print -u2 "Build it with Scripts/build-app.sh or pass an app bundle path."
  exit 1
fi
/bin/mkdir -p "$destination_dir" "$cli_dir"
if [[ -e "$destination" ]]; then
  backup="$destination_dir/MeetingRecorder.app.backup.$(/bin/date +%Y%m%d%H%M%S)"
  /bin/mv "$destination" "$backup"
  print "Previous installation moved to $backup"
fi
/usr/bin/ditto "$source_app" "$destination"
/bin/ln -sfn "$destination/Contents/Helpers/meeting-recorder" "$cli_dir/meeting-recorder"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"
print "Installed $destination"
print "CLI: $cli_dir/meeting-recorder"
print "Next: $cli_dir/meeting-recorder setup"
