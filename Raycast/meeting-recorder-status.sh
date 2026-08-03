#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title recorder status
# @raycast.mode compact
# @raycast.packageName Meeting Recorder

# Optional parameters:
# @raycast.icon 🎙️

exec "$HOME/Applications/MeetingRecorder.app/Contents/Helpers/meeting-recorder" status
