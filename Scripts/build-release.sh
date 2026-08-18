#!/bin/sh
set -eu

usage() {
    echo "usage: $0 VERSION [OUTPUT_DIRECTORY]" >&2
    echo "example: $0 0.1.0 dist/release" >&2
    exit 64
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

version=${1#v}
case "$version" in
    ''|*[!0-9A-Za-z.-]*) usage ;;
esac
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || usage

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
output_dir=${2:-"$repo_dir/dist/release"}
case "$output_dir" in
    /*) ;;
    *) output_dir="$repo_dir/$output_dir" ;;
esac

build_number=${KIYO_BUILD_NUMBER:-1}
case "$build_number" in
    ''|*[!0-9]*)
        echo "KIYO_BUILD_NUMBER must contain only digits" >&2
        exit 64
        ;;
esac

signing_identity=${KIYO_CODESIGN_IDENTITY:--}
tag="v$version"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiyo-release.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

build_architecture() {
    architecture=$1
    triple="$architecture-apple-macosx12.0"
    scratch="$work_dir/build-$architecture"
    destination="$work_dir/bin-$architecture"

    swift build \
        --package-path "$repo_dir" \
        --scratch-path "$scratch" \
        --configuration release \
        --triple "$triple" \
        --product kiyoctl
    swift build \
        --package-path "$repo_dir" \
        --scratch-path "$scratch" \
        --configuration release \
        --triple "$triple" \
        --product KiyoMenu

    bin_path=$(swift build \
        --package-path "$repo_dir" \
        --scratch-path "$scratch" \
        --configuration release \
        --triple "$triple" \
        --show-bin-path)

    mkdir -p "$destination"
    install -m 755 "$bin_path/kiyoctl" "$destination/kiyoctl"
    install -m 755 "$bin_path/KiyoMenu" "$destination/KiyoMenu"
}

build_architecture arm64
build_architecture x86_64

universal_dir="$work_dir/universal"
app_path="$work_dir/KiyoMenu.app"
cli_bundle="$work_dir/kiyoctl-$tag-macos-universal"
mkdir -p "$universal_dir" "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$cli_bundle"

lipo -create \
    "$work_dir/bin-arm64/kiyoctl" \
    "$work_dir/bin-x86_64/kiyoctl" \
    -output "$universal_dir/kiyoctl"
lipo -create \
    "$work_dir/bin-arm64/KiyoMenu" \
    "$work_dir/bin-x86_64/KiyoMenu" \
    -output "$universal_dir/KiyoMenu"
chmod 755 "$universal_dir/kiyoctl" "$universal_dir/KiyoMenu"

lipo "$universal_dir/kiyoctl" -verify_arch arm64 x86_64
lipo "$universal_dir/KiyoMenu" -verify_arch arm64 x86_64

install -m 755 "$universal_dir/KiyoMenu" "$app_path/Contents/MacOS/KiyoMenu"
install -m 644 "$repo_dir/App/KiyoMenu/Info.plist" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"

codesign_options="--force --sign"
if [ "$signing_identity" = "-" ]; then
    codesign $codesign_options - --timestamp=none "$universal_dir/kiyoctl"
    codesign $codesign_options - --timestamp=none "$app_path"
else
    codesign $codesign_options "$signing_identity" --options runtime --timestamp "$universal_dir/kiyoctl"
    codesign $codesign_options "$signing_identity" --options runtime --timestamp "$app_path"
fi

codesign --verify --strict --verbose=2 "$universal_dir/kiyoctl"
codesign --verify --deep --strict --verbose=2 "$app_path"

install -m 755 "$universal_dir/kiyoctl" "$cli_bundle/kiyoctl"
install -m 644 "$repo_dir/README.md" "$cli_bundle/README.md"
install -m 644 "$repo_dir/LICENSE" "$cli_bundle/LICENSE"

mkdir -p "$output_dir"
cli_archive="$output_dir/kiyoctl-$tag-macos-universal.zip"
app_archive="$output_dir/KiyoMenu-$tag-macos-universal.zip"
checksums="$output_dir/SHA256SUMS.txt"
rm -f "$cli_archive" "$app_archive" "$checksums"

ditto -c -k --sequesterRsrc --keepParent "$cli_bundle" "$cli_archive"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$app_archive"

(
    cd "$output_dir"
    LC_ALL=C shasum -a 256 \
        "$(basename "$app_archive")" \
        "$(basename "$cli_archive")"
) > "$checksums"

echo "$app_archive"
echo "$cli_archive"
echo "$checksums"
