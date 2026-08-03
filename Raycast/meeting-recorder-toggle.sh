#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title recorder
# @raycast.mode compact
# @raycast.packageName Meeting Recorder

# Optional parameters:
# @raycast.icon 🎙️
# @raycast.description Start or stop a local meeting audio recording
# @raycast.argument1 { "type": "text", "placeholder": "App name: meet, teams…", "optional": true }

if [[ -n "${1:-}" ]]; then
  exec "$HOME/Applications/MeetingRecorder.app/Contents/Helpers/meeting-recorder" toggle --app "$1"
fi
exec "$HOME/Applications/MeetingRecorder.app/Contents/Helpers/meeting-recorder" toggle
