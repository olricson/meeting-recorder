#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title recorder
# @raycast.mode compact
# @raycast.packageName Meeting Recorder

# Optional parameters:
# @raycast.icon 🎙️
# @raycast.description Start or stop a local Google Meet audio recording

exec "$HOME/Applications/MeetingRecorder.app/Contents/Helpers/meeting-recorder" toggle
