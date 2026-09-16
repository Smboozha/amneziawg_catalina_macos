#!/usr/bin/env bash
#
# Build AmneziaWG (AmneziaWG.app) for macOS with all embedded parts
# (Packet Tunnel Network Extension + Login Item Helper) in one shot.
#
# Designed to run locally on any Mac with Xcode + Go, and on GitHub Actions
# macOS runners. The macOS 10.15 deployment target is baked into the
# project/package settings, so the resulting app runs on Catalina (10.15).
#
# An unsigned/ad-hoc build is intended for development and for producing an
# installable DMG. A fully working Packet Tunnel requires a signed build with
# the Network Extensions capability (see docs/macos-signing.md).
#
# Environment overrides:
#   DEVELOPMENT_TEAM       Apple Developer Team ID (for --signed)
#   APP_ID_MACOS           macOS bundle id (default: org.amnezia.awg)
#   ALLOW_PROVISIONING_UPDATES=1  allow Xcode to manage provisioning
#   AWG_GO_BIN_DIR         directory containing the `go` binary (default: PATH)
#   AWG_BUILD_TMP_ROOT     temp root for the source copy + DerivedData
#   AWG_BUILD_OUTPUT_ROOT  where archives/zip land (default: <repo>/build)
#
# Options are provided for convenience but the script is safe to run with no
# arguments (unsigned local build).

set -euo pipefail

PROJECT_NAME="AmneziaWG"

usage() {
    cat <<USAGE
Usage: scripts/build-macos.sh [options]

Build the macOS app (AmneziaWG.app) with its Network Extension and login
helper, producing a zip archive in build/.

Options:
  --configuration NAME   Xcode configuration to build [Debug]
  --signed               Use normal Apple signing (requires DEVELOPMENT_TEAM)
  --unsigned             Disable Apple signing and apply ad-hoc signing [default]
  --run-swiftlint        Run SwiftLint build phases
  --skip-swiftlint       Skip SwiftLint build phases [default]
  --no-archive           Do not create a zip in build/
  --no-clean             Reuse the temp source copy and DerivedData
  -h, --help             Show this help

Environment overrides:
  AWG_GO_BIN_DIR         Go 1.24+ bin directory (default: first go on PATH)
  AWG_BUILD_TMP_ROOT     Temp build root (default: /private/tmp/awg-apple-build)
  AWG_BUILD_STAMP        Archive timestamp override
  DEVELOPMENT_TEAM       Optional xcodebuild override (for --signed)
  APP_ID_MACOS           Optional bundle id override
  ALLOW_PROVISIONING_UPDATES=1 adds -allowProvisioningUpdates in signed mode
USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

go_version_at_least_1_24() {
    local version="${1#go}"
    local major="${version%%.*}"
    local rest="${version#*.}"
    local minor="${rest%%.*}"

    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 1 || (major == 1 && minor >= 24) ))
}

configuration="Debug"
signing_mode="unsigned"
skip_swiftlint=1
create_archive=1
clean=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || die "--configuration requires a value"
            configuration="$2"
            shift 2
            ;;
        --signed)
            signing_mode="signed"
            shift
            ;;
        --unsigned)
            signing_mode="unsigned"
            shift
            ;;
        --run-swiftlint)
            skip_swiftlint=0
            shift
            ;;
        --skip-swiftlint)
            skip_swiftlint=1
            shift
            ;;
        --no-archive)
            create_archive=0
            shift
            ;;
        --no-clean)
            clean=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

require_command xcodebuild
require_command rsync
require_command ditto
require_command codesign

# Resolve Go toolchain. AmneziaWG 2.0 requires Go 1.24+ to build the bridge.
go_bin_dir="${AWG_GO_BIN_DIR:-}"
if [[ -z "$go_bin_dir" ]]; then
    require_command go
    go_bin_dir="$(dirname "$(command -v go)")"
fi
[[ -x "$go_bin_dir/go" ]] || die "Go not found at $go_bin_dir/go; set AWG_GO_BIN_DIR"
go_version="$("$go_bin_dir/go" version 2>/dev/null | awk '{print $3}')"
go_version_at_least_1_24 "$go_version" || die "AmneziaWG 2.0 Go bridge requires Go 1.24+; found $go_version"

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="${AWG_BUILD_TMP_ROOT:-/private/tmp/awg-apple-build}"
source_copy="$tmp_root/source"
derived_data="$tmp_root/DerivedData"
go_build_cache="$tmp_root/go-build-cache"
go_mod_cache="$tmp_root/go-mod-cache"
output_root="${AWG_BUILD_OUTPUT_ROOT:-$project_root/build}"

if [[ "$clean" -eq 1 ]]; then
    rm -rf "$source_copy" "$derived_data"
fi
mkdir -p "$tmp_root" "$go_build_cache" "$go_mod_cache"

# Copy the source to a path without spaces (the WireGuardKitGo Makefile / Go
# toolchain are sensitive to spaces).
rsync -a --delete \
    --exclude '/.git/' \
    --exclude '/build/' \
    --exclude '/DerivedData/' \
    --exclude 'xcuserdata/' \
    --exclude '*.xcuserstate' \
    --exclude '/scripts/' \
    --exclude '/.github/' \
    --exclude '/docs/' \
    --exclude '/Tests/' \
    "$project_root/" "$source_copy/"

# Ensure a Developer.xcconfig exists in the copy (nil-safe for unsigned builds).
developer_xcconfig="$source_copy/Sources/WireGuardApp/Config/Developer.xcconfig"
if [[ ! -f "$developer_xcconfig" ]]; then
    mkdir -p "$(dirname "$developer_xcconfig")"
    printf '// Generated by scripts/build-macos.sh for local builds.\nDEVELOPMENT_TEAM = %s\nAPP_ID_MACOS = %s\n' \
        "${DEVELOPMENT_TEAM:-}" "${APP_ID_MACOS:-org.amnezia.awg}" > "$developer_xcconfig"
fi

xcodebuild_args=()
signing_args=()
[[ "$signing_mode" == "signed" && "${ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]] &&
    signing_args+=("-allowProvisioningUpdates")

if [[ "$signing_mode" == "signed" ]]; then
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] || die "signed mode requires DEVELOPMENT_TEAM"
    xcodebuild_args+=(CODE_SIGN_IDENTITY="Mac Developer" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
else
    # Ad-hoc / unsigned local build: подписываем ad-hoc (identity "-"),
    # чтобы .app был валидно подписан для проверок (codesign --verify,
    # Gatekeeper на локальном запуске). Реальная подпись не нужна.
    signing_args+=(
        CODE_SIGN_IDENTITY="-"
        CODE_SIGN_STYLE=Manual
        CODE_SIGNING_ALLOWED=YES
        CODE_SIGNING_REQUIRED=YES
        DEVELOPMENT_TEAM=""
    )
fi

xcodebuild_args+=(
    -project "$source_copy/WireGuard.xcodeproj"
    -scheme AmneziaWG
    -configuration "$configuration"
    -derivedDataPath "$derived_data"
)

if [[ "$skip_swiftlint" -eq 1 ]]; then
    xcodebuild_args+=(SKIP_SWIFTLINT=1)
fi

(
    cd "$source_copy"
    env \
        "PATH=$go_bin_dir:$PATH" \
        "GOCACHE=$go_build_cache" \
        "GOMODCACHE=$go_mod_cache" \
        xcodebuild "${xcodebuild_args[@]}" "${signing_args[@]}" build
)

app_path="$derived_data/Build/Products/$configuration/AmneziaWG.app"
[[ -d "$app_path" ]] || die "expected app not found: $app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ "$create_archive" -eq 1 ]]; then
    stamp="${AWG_BUILD_STAMP:-$(date +%Y%m%d-%H%M)}"
    configuration_slug="$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')"
    signing_slug="$signing_mode"
    [[ "$signing_mode" == "unsigned" ]] && signing_slug="ad-hoc"
    output_dir="$output_root/macos-$configuration_slug-$stamp"
    zip_path="$output_dir/AmneziaWG-macos-$configuration_slug-$signing_slug-$stamp.zip"

    mkdir -p "$output_dir"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

    echo "Archive: $zip_path"
fi

echo "App: $app_path"
