#!/bin/zsh
set -eu
cd "$(dirname "$0")"
# Start from an empty bundle so files dropped from the build never linger in it.
rm -rf 'Clipdan.app'
mkdir -p 'Clipdan.app/Contents/MacOS' 'Clipdan.app/Contents/Resources' .build/app-icon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p .build/module-cache
clipdan_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swift -module-cache-path "$clipdan_cache_path" sources/icon.swift .build/app-icon.iconset 'Clipdan.app/Contents/Resources/app-icon.icns'
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$clipdan_cache_path" -swift-version 5 -O -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement sources/clips.swift sources/main.swift -o 'Clipdan.app/Contents/MacOS/clipdan'
cat > 'Clipdan.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>clipdan</string>
<key>CFBundleIdentifier</key><string>local.clipdan</string>
<key>CFBundleName</key><string>Clipdan</string>
<key>CFBundleDisplayName</key><string>Clipdan</string>
<key>CFBundleIconFile</key><string>app-icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# App Sandbox with no entitlements beyond it: no network, and no file access outside its own container.
cat > .build/clipdan.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
# Ad-hoc by default, which runs only on this Mac. To share the app, set CLIPDAN_SIGN_IDENTITY to a Developer ID
# Application identity, then notarize it (see readme.md); a secure timestamp is required for notarization.
identity="${CLIPDAN_SIGN_IDENTITY:--}"
timestamp=()
[[ "$identity" == - ]] || timestamp=(--timestamp)
codesign --force --sign "$identity" "${timestamp[@]}" --options runtime --entitlements .build/clipdan.entitlements 'Clipdan.app'
echo 'Built Clipdan.app'
if [[ "${1:-}" == "--install" ]]; then
  # Replace only an earlier Clipdan, never another app with the same name.
  if [[ -e '/Applications/Clipdan.app' && "$(plutil -extract CFBundleIdentifier raw -o - '/Applications/Clipdan.app/Contents/Info.plist' 2>/dev/null || true)" != local.clipdan ]]; then
    echo '/Applications/Clipdan.app is not Clipdan; leaving it in place.' >&2; exit 1
  fi
  # Quit every running copy first, wherever it was started; it finishes saving the history before exiting. Matched by
  # bundle ID, like the app's own one-copy check, so a copy still running would also make the new one quit at launch.
  running() { [[ -n "$(lsappinfo find bundleid=local.clipdan)" ]] }
  # A refused quit request (such as a declined Automation prompt) is caught by the check below.
  if running; then osascript -e 'tell application id "local.clipdan" to quit' >/dev/null 2>&1 || true; fi
  for _ in {1..50}; do running || break; sleep 0.2; done
  if running; then echo 'Clipdan is still running; quit it, then run ./build.sh --install again.' >&2; exit 1; fi
  rm -rf '/Applications/Clipdan.app'
  ditto 'Clipdan.app' '/Applications/Clipdan.app'
  # Only the installed copy should handle Launch at Login.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/Clipdan.app" 2>/dev/null || true  # Fails when it was never registered.
  open '/Applications/Clipdan.app'
  echo 'Installed and opened /Applications/Clipdan.app'
fi
