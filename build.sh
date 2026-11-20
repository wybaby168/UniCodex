#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
mode=${1:---install}
architectures=("$(/usr/bin/uname -m)")
case "$mode" in
  --install)
    parent=/Applications
    action=install
    ;;
  --build-only)
    parent="$project_dir/build"
    action=stage
    ;;
  --release)
    parent="$project_dir/build"
    action=archive
    architectures=(arm64 x86_64)
    ;;
  -h|--help)
    printf '%s\n' "Usage: ./build.sh [--install | --build-only | --release]" \
      "  --install     Build and install /Applications/UniCodex.app (default)." \
      "  --build-only  Write build/UniCodex.app for inspection." \
      "  --release     Package a locally signed universal app and checksum in build/."
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$mode" >&2
    exit 2
    ;;
esac
if (( $# > 1 )); then
  printf '%s\n' 'Expected one build option.' >&2
  exit 2
fi

mkdir -p "$parent"
staging=$(/usr/bin/mktemp -d "$parent/.unicodex-build.XXXXXX")
trap '/bin/rm -rf -- "$staging"' EXIT
bundle="$staging/UniCodex.app"
resources="$bundle/Contents/Resources"
source_resources="$project_dir/Resources"
icon_info="$staging/icon-info.plist"

mkdir -p "$bundle/Contents/MacOS" "$resources"
executables=()
for architecture in "${architectures[@]}"; do
  executable="$staging/APIWorkbench-$architecture"
  /usr/bin/xcrun swiftc -swift-version 5 -target "$architecture-apple-macosx14.0" -O \
    "$project_dir"/Sources/UniCodex/*.swift -o "$executable"
  executables+=("$executable")
done
if (( $#executables == 1 )); then
  /bin/mv "$executables[1]" "$bundle/Contents/MacOS/APIWorkbench"
else
  /usr/bin/lipo -create "${executables[@]}" -output "$bundle/Contents/MacOS/APIWorkbench"
fi

/usr/bin/xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 \
  --target-device mac --app-icon UniCodex --output-partial-info-plist "$icon_info" \
  --output-format human-readable-text --warnings --errors \
  "$source_resources/UniCodex.icon" "$source_resources/ProviderMarks.xcassets"

/bin/cp "$source_resources"/CodexModels.json "$source_resources"/CodexCatalog-*.txt \
  "$source_resources"/ProviderMarks-SOURCE.txt "$resources"
for pack in "$source_resources"/Localization/*.lproj; do
  /usr/bin/plutil -lint "$pack/Localizable.strings"
  /bin/cp -R "$pack" "$resources/"
done
/bin/cp "$source_resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge \"$icon_info\"" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"

python3 "$project_dir/Scripts/bundle.py" sign "$bundle"
if [[ "$action" == archive ]]; then
  archive=UniCodex-macos-universal.zip
  /usr/bin/codesign --verify --deep --strict "$bundle"
  (
    cd "$staging"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent UniCodex.app "$archive"
    /usr/bin/shasum -a 256 "$archive" > SHA256SUMS
  )
  /bin/mv "$staging/$archive" "$staging/SHA256SUMS" "$parent/"
  printf '%s\n' "$parent/$archive" "$parent/SHA256SUMS"
else
  python3 "$project_dir/Scripts/bundle.py" "$action" "$bundle"
fi
