#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
mode=${1:---install}
case "$mode" in
  --install)
    parent=/Applications
    action=install
    ;;
  --build-only)
    parent="$project_dir/build"
    action=stage
    ;;
  -h|--help)
    printf '%s\n' "Usage: ./build.sh [--install | --build-only]" \
      "  --install     Build and install /Applications/UniCodex.app (default)." \
      "  --build-only  Write build/UniCodex.app for inspection."
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
target="$(/usr/bin/uname -m)-apple-macosx14.0"

mkdir -p "$bundle/Contents/MacOS" "$resources"
/usr/bin/xcrun swiftc -swift-version 5 -target "$target" -O \
  "$project_dir"/Sources/UniCodex/*.swift \
  -o "$bundle/Contents/MacOS/APIWorkbench"

/usr/bin/xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 \
  --target-device mac --app-icon UniCodex --output-partial-info-plist "$icon_info" \
  --output-format human-readable-text --warnings --errors "$source_resources/UniCodex.icon"

/bin/cp "$source_resources"/CodexModels.json "$source_resources"/CodexCatalog-*.txt "$resources"
for pack in "$source_resources"/Localization/*.lproj; do
  /usr/bin/plutil -lint "$pack/Localizable.strings"
  /bin/cp -R "$pack" "$resources/"
done
/bin/cp "$source_resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge \"$icon_info\"" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"

python3 "$project_dir/Scripts/bundle.py" sign "$bundle"
python3 "$project_dir/Scripts/bundle.py" "$action" "$bundle"
