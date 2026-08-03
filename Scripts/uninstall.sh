#!/bin/zsh
set -euo pipefail

app="$HOME/Applications/MeetingRecorder.app"
cli="$HOME/.local/bin/meeting-recorder"
raycast_dir="$HOME/raycast-scripts"
support_dir="$HOME/Library/Application Support/MeetingRecorder"
logs_dir="$HOME/Library/Logs/MeetingRecorder"
state_file="$support_dir/state.json"
script_name="${0:t}"
force=false
purge_data=false

usage() {
  print "Usage: $script_name [--force] [--purge-data]"
  print ""
  print "  --force       Allow uninstall while the agent reports active work."
  print "  --purge-data  Also remove configuration, models, state, and central logs."
  print ""
  print "Recordings, privacy permissions, signing certificates, private keys,"
  print "and MeetingRecorder.app.backup.* installations are never removed."
}

while (( $# > 0 )); do
  case "$1" in
    --force) force=true ;;
    --purge-data) purge_data=true ;;
    --help|-h) usage; exit 0 ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

agent_pattern="^${app}/Contents/MacOS/MeetingRecorderAgent$"
agent_running=false
if /usr/bin/pgrep -f "$agent_pattern" >/dev/null 2>&1; then
  agent_running=true
fi

active_work=false
state_is_readable=false
if [[ -f "$state_file" ]] && /usr/bin/grep -Eq \
  '"phase"[[:space:]]*:[[:space:]]*"(idle|starting|recording|finalizing|transcribing|failed)"' \
  "$state_file"; then
  state_is_readable=true
fi
if [[ -f "$state_file" ]] && /usr/bin/grep -Eq \
  '"phase"[[:space:]]*:[[:space:]]*"(starting|recording|finalizing|transcribing)"' \
  "$state_file"; then
  active_work=true
fi

if $agent_running && ! $state_is_readable && ! $force; then
  print -u2 "MeetingRecorder is running but its state could not be verified."
  print -u2 "Nothing was removed. Rerun with --force only if interrupting the agent is acceptable."
  exit 1
fi

if $agent_running && $active_work && ! $force; then
  print -u2 "MeetingRecorder is recording, finalizing, or transcribing."
  print -u2 "Stop or finish that work first, or rerun with --force to request a graceful termination."
  exit 1
fi

if $agent_running; then
  print "Requesting MeetingRecorder agent termination..."
  /usr/bin/pkill -TERM -f "$agent_pattern" || true
  for _ in {1..50}; do
    if ! /usr/bin/pgrep -f "$agent_pattern" >/dev/null 2>&1; then
      agent_running=false
      break
    fi
    /bin/sleep 0.2
  done
  if $agent_running; then
    print -u2 "The MeetingRecorder agent did not terminate; nothing was removed."
    exit 1
  fi
fi

if [[ -d "$app" ]]; then
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "com.olivier.meetingrecorder" ]]; then
    print -u2 "Refusing to remove unexpected application at $app"
    print -u2 "Bundle identifier was: ${bundle_id:-unreadable}"
    exit 1
  fi
  /bin/rm -rf "$app"
  print "Removed $app"
else
  print "App was not installed at $app"
fi

expected_cli_target="$app/Contents/Helpers/meeting-recorder"
if [[ -L "$cli" ]]; then
  cli_target="$(/usr/bin/readlink "$cli")"
  if [[ "$cli_target" == "$expected_cli_target" ]]; then
    /bin/rm "$cli"
    print "Removed $cli"
  else
    print -u2 "Preserved unexpected CLI symlink at $cli -> $cli_target"
  fi
elif [[ -e "$cli" ]]; then
  print -u2 "Preserved non-symlink CLI at $cli"
fi

for raycast_name in meeting-recorder-toggle.sh meeting-recorder-status.sh; do
  raycast_script="$raycast_dir/$raycast_name"
  if [[ -f "$raycast_script" ]] \
    && /usr/bin/grep -Fq '@raycast.packageName Meeting Recorder' "$raycast_script" \
    && /usr/bin/grep -Fq 'MeetingRecorder.app/Contents/Helpers/meeting-recorder' "$raycast_script"; then
    /bin/rm "$raycast_script"
    print "Removed $raycast_script"
  elif [[ -e "$raycast_script" ]]; then
    print -u2 "Preserved modified or unrelated Raycast script at $raycast_script"
  fi
done

if $purge_data; then
  if [[ -d "$support_dir" ]]; then
    /bin/rm -rf "$support_dir"
    print "Removed $support_dir"
  fi
  if [[ -d "$logs_dir" ]]; then
    /bin/rm -rf "$logs_dir"
    print "Removed $logs_dir"
  fi
else
  print "Preserved configuration, models, state, and logs. Use --purge-data to remove them."
fi

/bin/rmdir "$HOME/.local/bin" 2>/dev/null || true
/bin/rmdir "$raycast_dir" 2>/dev/null || true
/bin/rmdir "$HOME/Applications" 2>/dev/null || true

print "MeetingRecorder uninstall complete. Recordings, permissions, certificates, keys, backups, and recording-folder debug logs were preserved."
