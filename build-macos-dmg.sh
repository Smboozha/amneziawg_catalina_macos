#!/usr/bin/env bash
#
# Build AmneziaWG.app (macOS, target 10.15) via scripts/build-macos.sh and wrap
# it into an installable DMG for drag-and-drop into /Applications.
#
# Only runs on macOS (needs Xcode + hdiutil). On GitHub Actions this executes
# on a `macos-15` runner and the DMG is uploaded as an artifact you download,
# open, and drag AmneziaWG.app to Applications.
#
# Environment overrides (forwarded to scripts/build-macos.sh where relevant):
#   AWG_GO_BIN_DIR          Go 1.24+ bin directory (default: first go on PATH)
#   AWG_BUILD_TMP_ROOT      Temp build root (default: /private/tmp/awg-apple-build)
#   AWG_BUILD_OUTPUT_ROOT   Output/artifact root (default: <repo>/build)
#   AWG_DMG_VOLUME_NAME     DMG volume name (default: AmneziaWG)
#   AWG_DMG_FILE_NAME       DMG file name override
#   DEVELOPMENT_TEAM        Apple Developer Team ID (only with --signed)
#   ALLOW_PROVISIONING_UPDATES=1 adds -allowProvisioningUpdates in signed mode
#
# Options are forwarded to scripts/build-macos.sh; see its --help.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<USAGE
Usage: scripts/build-macos-dmg.sh [options forwarded to scripts/build-macos.sh]

Build AmneziaWG.app and package it into an installable DMG.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

for cmd in hdiutil; do
    require_command "$cmd"
done

build_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --signed)
            build_args+=(--signed)
            shift
            ;;
        --unsigned)
            build_args+=(--unsigned)
            shift
            ;;
        --signed-with-adhoc-login)
            build_args+=(--signed-with-adhoc-login)
            shift
            ;;
        --skip-swiftlint)
            build_args+=(--skip-swiftlint)
            shift
            ;;
        --run-swiftlint)
            build_args+=(--run-swiftlint)
            shift
            ;;
        --sanity-check)
            build_args+=(--sanity-check)
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            build_args+=("$1")
            shift
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

# Build; scripts/build-macos.sh prints "App: <path>".
build_log="$("$script_dir/build-macos.sh" "${build_args[@]}" 2>&1 | tee /dev/stderr)"
app_path="$(printf '%s\n' "$build_log" | sed -n 's/^App: //p' | tail -n 1)"

[ -d "$app_path" ] || die "could not determine app path"

volume_name="${AWG_DMG_VOLUME_NAME:-AmneziaWG}"
trap 'rm -rf "${staging_dir:-}"' EXIT
staging_dir="$(mktemp -d)"
stamp="$(date +%Y%m%d-%H%M)"
output_root="${AWG_BUILD_OUTPUT_ROOT:-$project_root/build}"
dmg_dir="$output_root/dmg-$stamp"
dmg_path="$dmg_dir/$volume_name-macos-$stamp.dmg"
mkdir -p "$dmg_dir"

# Drag-and-drop layout: the app + a symlink to /Applications.
ditto "$app_path" "$staging_dir/AmneziaWG.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

hdiutil verify "$dmg_path"
echo "DMG: $dmg_path"
