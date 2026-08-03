#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
cd "$repo_dir"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/public-check-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/public-check-swiftpm-cache"
swiftpm_cache="$repo_dir/.build/public-check-cache"
swiftpm_config="$repo_dir/.build/public-check-config"
swiftpm_security="$repo_dir/.build/public-check-security"
/bin/mkdir -p "$swiftpm_cache" "$swiftpm_config" "$swiftpm_security"

fail() {
    print -u2 "Public repository check failed: $1"
    exit 1
}

scan_publishable_text() {
    local pattern="$1"
    local excluded_file="${2:-}"
    local found=false
    local file
    while IFS= read -r file; do
        [[ -z "$file" || "$file" == "$excluded_file" || ! -f "$file" ]] && continue
        if /usr/bin/grep -I -q -E "$pattern" "$file"; then
            print -u2 "Potentially sensitive text in $file:"
            /usr/bin/grep -I -n -E "$pattern" "$file" >&2 || true
            found=true
        fi
    done <<< "$publishable_files"
    $found
}

if ! /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "not inside a Git worktree."
fi

publishable_files="$(/usr/bin/git ls-files --cached --others --exclude-standard)"
public_history="$(/usr/bin/git rev-list --objects --branches --tags 2>/dev/null || true)"

private_path_pattern='(^|/)(exemples?|recordings?|Meetings Recordings)(/|$)'
sensitive_file_pattern='(^|/)(\.env($|\.)|[^/]+\.(p12|pfx|pem|cer|crt|key|m4a|aac|caf|flac|mp3|mp4|mov|wav))$'

if print -r -- "$publishable_files" | /usr/bin/grep -Eiq "$private_path_pattern"; then
    print -r -- "$publishable_files" | /usr/bin/grep -Ei "$private_path_pattern" >&2 || true
    fail "a private recording directory would be published."
fi

if print -r -- "$publishable_files" | /usr/bin/grep -Eiq "$sensitive_file_pattern"; then
    print -r -- "$publishable_files" | /usr/bin/grep -Ei "$sensitive_file_pattern" >&2 || true
    fail "a credential, certificate, recording, or media file would be published."
fi

if print -r -- "$public_history" | /usr/bin/grep -Eiq "$private_path_pattern|$sensitive_file_pattern"; then
    print -r -- "$public_history" | /usr/bin/grep -Ei "$private_path_pattern|$sensitive_file_pattern" >&2 || true
    fail "a branch or tag contains a private artifact in its history."
fi

if scan_publishable_text \
    'BEGIN ([A-Z0-9]+ )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}' \
    'Scripts/check-public-repo.sh'; then
    fail "publishable text looks like a private key or access token."
fi

if scan_publishable_text '/Users/[^/$[:space:]]+' 'Scripts/check-public-repo.sh'; then
    fail "a publishable file contains an absolute macOS home path."
fi

while IFS= read -r shell_file; do
    [[ -z "$shell_file" ]] && continue
    /bin/zsh -n "$shell_file" || fail "invalid shell syntax in $shell_file."
done < <(print -r -- "$publishable_files" | /usr/bin/grep -E '^(Scripts|Raycast)/[^/]+\.sh$' || true)

while IFS= read -r plist_file; do
    [[ -z "$plist_file" ]] && continue
    /usr/bin/plutil -lint "$plist_file" >/dev/null || fail "invalid plist syntax in $plist_file."
done < <(print -r -- "$publishable_files" | /usr/bin/grep -E '^AppResources/[^/]+\.(plist|entitlements)$' || true)

/usr/bin/swift package \
    --cache-path "$swiftpm_cache" \
    --config-path "$swiftpm_config" \
    --security-path "$swiftpm_security" \
    --disable-sandbox dump-package >/dev/null
/usr/bin/git diff --check
/usr/bin/git diff --cached --check

print "Public repository checks passed."
print "Checked publishable files plus all branch/tag history; push the intended branch, never local refs with --mirror."
