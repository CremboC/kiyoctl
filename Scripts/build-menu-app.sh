#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
scratch_path=${KIYO_BUILD_PATH:-"$repo_dir/.build-menu"}
app_path="$repo_dir/dist/KiyoMenu.app"

swift build \
    --package-path "$repo_dir" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --product KiyoMenu

bin_path=$(swift build \
    --package-path "$repo_dir" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --show-bin-path)

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$bin_path/KiyoMenu" "$app_path/Contents/MacOS/KiyoMenu"
install -m 644 "$repo_dir/App/KiyoMenu/Info.plist" "$app_path/Contents/Info.plist"

# Ad-hoc signing creates a launchable local bundle without enabling App Sandbox
# or granting any entitlements. Distribution signing can be added later.
codesign --force --sign - --timestamp=none "$app_path"

echo "$app_path"
