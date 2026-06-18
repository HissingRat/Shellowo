#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This packaging script must run on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="${1:-0.0.0}"
dist_dir="${2:-dist}"
min_macos="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
build_version="${BUILD_VERSION:-${GITHUB_RUN_NUMBER:-1}}"
arch="$(uname -m)"

bundle_version="${version#v}"
bundle_version="$(printf '%s' "$bundle_version" | sed -E 's/[^0-9.].*$//; s/^\.*//; s/\.*$//')"
if [[ -z "$bundle_version" ]]; then
    bundle_version="0.0.0"
fi
build_version="$(printf '%s' "$build_version" | tr -cd '0-9.')"
if [[ -z "$build_version" ]]; then
    build_version="1"
fi

work_dir="$repo_root/zig-out/macos-package"
install_dir="$work_dir/install"
app_dir="$work_dir/Shellowo.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
iconset_dir="$work_dir/Shellowo.iconset"

rm -rf "$work_dir"
mkdir -p "$install_dir" "$macos_dir" "$resources_dir" "$iconset_dir" "$dist_dir"

zig build -Doptimize=ReleaseFast --prefix "$install_dir"
install -m 0755 "$install_dir/bin/Shellowo" "$macos_dir/Shellowo"

sed \
    -e "s/@VERSION@/$bundle_version/g" \
    -e "s/@BUILD_VERSION@/$build_version/g" \
    -e "s/@MIN_MACOS@/$min_macos/g" \
    packaging/macos/Info.plist > "$contents_dir/Info.plist"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/owo.png --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" assets/owo.png --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$resources_dir/Shellowo.icns"

cp LICENSE README.md "$resources_dir/"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi

plutil -lint "$contents_dir/Info.plist"
codesign --verify --deep --strict "$app_dir"

archive_name="Shellowo-${version}-macos-${arch}.zip"
rm -f "$dist_dir/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$dist_dir/$archive_name"

rm -rf "$dist_dir/Shellowo.app"
ditto "$app_dir" "$dist_dir/Shellowo.app"

echo "$dist_dir/Shellowo.app"
echo "$dist_dir/$archive_name"
