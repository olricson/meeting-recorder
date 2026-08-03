#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
identity="${MEETING_RECORDER_SIGNING_IDENTITY:-MeetingRecorder Local Code Signing}"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

cd "$repo_dir"
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"${identity}\""; then
  print -u2 "Code-signing identity '${identity}' was not found."
  print -u2 "Run Scripts/create-local-signing-certificate.sh first."
  exit 1
fi

sdk_root="${MEETING_RECORDER_SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
if [[ "$sdk_root" == /Library/Developer/CommandLineTools/*/MacOSX.sdk && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  sdk_root=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
export SDKROOT="$sdk_root"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/swiftpm-cache"

/usr/bin/swift build --disable-sandbox -c release --arch arm64
bin_dir="$(/usr/bin/swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"
dist_dir="$repo_dir/dist"
app="$dist_dir/MeetingRecorder.app"
staging="$dist_dir/.MeetingRecorder.app.staging.$$"

/bin/mkdir -p "$dist_dir"
if [[ -e "$staging" ]]; then /bin/rm -rf "$staging"; fi
/bin/mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Helpers" "$staging/Contents/Resources"
/bin/cp "$repo_dir/AppResources/Info.plist" "$staging/Contents/Info.plist"
/bin/cp "$repo_dir/AppResources/ThirdPartyNotices.txt" "$staging/Contents/Resources/ThirdPartyNotices.txt"
icon_source="$repo_dir/icone.png"
iconset="$repo_dir/.build/MeetingRecorder.iconset"
if [[ ! -f "$icon_source" ]]; then
  print -u2 "App icon not found at repository root: $icon_source"
  exit 1
fi
if [[ -e "$iconset" ]]; then /bin/rm -rf "$iconset"; fi
/bin/mkdir -p "$iconset"
/usr/bin/sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$icon_source" --out "$iconset/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$iconset" -o "$staging/Contents/Resources/MeetingRecorder.icns"
/bin/rm -rf "$iconset"
/bin/cp "$bin_dir/MeetingRecorderAgent" "$staging/Contents/MacOS/MeetingRecorderAgent"
/bin/cp "$bin_dir/meeting-recorder" "$staging/Contents/Helpers/meeting-recorder"
/bin/chmod 755 "$staging/Contents/MacOS/MeetingRecorderAgent" "$staging/Contents/Helpers/meeting-recorder"

/usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" \
  "$staging/Contents/Helpers/meeting-recorder"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --entitlements "$repo_dir/AppResources/MeetingRecorder.entitlements" \
  --sign "$identity" "$staging"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staging"

if [[ -e "$app" ]]; then /bin/rm -rf "$app"; fi
/bin/mv "$staging" "$app"
/bin/cp "$repo_dir/Scripts/install-on-second-mac.sh" "$dist_dir/install-meeting-recorder.sh"
/bin/chmod 755 "$dist_dir/install-meeting-recorder.sh"
/bin/cp "$repo_dir/Raycast/meeting-recorder-toggle.sh" "$dist_dir/meeting-recorder-toggle.sh"
/bin/chmod 755 "$dist_dir/meeting-recorder-toggle.sh"
print "Built and signed $app"
