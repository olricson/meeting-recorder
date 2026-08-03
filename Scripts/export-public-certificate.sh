#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
output="$repo_dir/dist/MeetingRecorder-Local-Code-Signing.cer"
/bin/mkdir -p "${output:h}"
/usr/bin/security find-certificate -c "MeetingRecorder Local Code Signing" -p > "$output"
print "Exported the public certificate to $output"
print "This file has no private key and can be copied to the second Mac."
