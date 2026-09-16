#!/usr/bin/env bash
#
# Build AmneziaWG.app (via scripts/build-macos.sh) and wrap it into an
# installable DMG (drag-and-drop into /Applications).
#
# Requires macOS (Xcode + hdiutil). Runner-specific: on GitHub Actions this
# runs on a `macos-15` runner and the DMG is uploaded as an artifact.
#
# Environment overrides (forwarded where relevant):
#   AWG_GO_BIN_DIR          Go bin dir
#   AWG_BUILD_TMP_ROOT      Temp build root (default: /private/tmp/awg-apple-build)
#   AWG_DMG_OUTPUT_ROOT     DMG output dir (default: <repo>/build)
#   AWG_DMG_VOLUME_NAME     DMG volume name (default: AmneziaWG)
#   DEVELOPMENT_TEAM        Only with --signed
#
# Options are forwarded to scripts/build-macos.sh; see its --help for the
# full list.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"

die() { echo "error: $*" >&2; exit 1; }

for cmd in hdiutil ditto codesign; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

build_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || die "--configuration requires a value"
            build_args+=("--configuration" "$2")
            shift 2
            ;;
        --signed)
            build_args+=("--signed")
            shift
            ;;
        --unsigned)
            build_args+=("--unsigned")
            shift
            ;;
        --no-archive)
            build_args+=("--no-archive")
            shift
            ;;
        --no-clean)
            build_args+=("--no-clean")
            shift
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: scripts/build-macos-dmg.sh [options forwarded to build-macos.sh]

Build AmneziaWG.app and wrap it into an installable DMG.
USAGE
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

# Build and capture the path of the produced .app from build-macos.sh output.
build_log="$("$script_dir/build-macos.sh" "${build_args[@]}" --no-archive 2>&1 | tee /dev/stderr)"
app_path="$(printf '%s\n' "$build_log" | sed -n 's/^App: //p' | tail -n 1)"
[[ -n "$app_path" && -d "$app_path" ]] || die "could not determine built app path"

volume_name="${AWG_DMG_VOLUME_NAME:-AmneziaWG}"
stamp="$(date +%Y%m%d-%H%M)"
output_root="${AWG_DMG_OUTPUT_ROOT:-$project_root/build}"
output_dir="$output_root/dmg-$stamp"
dmg_path="$output_dir/$volume_name-macos-$stamp.dmg"
tmp_root="${AWG_BUILD_TMP_ROOT:-/private/tmp/awg-apple-build}"
staging_dir="$tmp_root/dmg-staging"

rm -rf "$staging_dir"
mkdir -p "$staging_dir" "$output_dir"

# Layout for drag-and-drop: app + /Applications alias.
ditto "$app_path" "$staging_dir/AmneziaWG.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

hdiutil verify "$dmg_path"

echo
echo "DMG: $dmg_path"
