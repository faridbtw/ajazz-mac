#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
destination="${1:-$PWD/build}"
mkdir -p "$destination"
staging="$(mktemp -d "$destination/.ajazz-build.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/ajazz-mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Editor"
cp Editor/* "$app/Contents/Resources/Editor/"
cp AjazzControl.icns "$app/Contents/Resources/"
cp Info.plist "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -warnings-as-errors -target "$arch-apple-macos14.2" \
        AjazzControl.swift Keyboard.swift DeviceEditor.swift EditorSession.swift Music.swift \
        -o "$staging/Editor-$arch"
    xcrun swiftc -swift-version 5 -O -warnings-as-errors -target "$arch-apple-macos14.2" \
        Spectrum.swift -o "$staging/Spectrum-$arch"
done
/usr/bin/lipo -create "$staging/Editor-arm64" "$staging/Editor-x86_64" \
    -output "$app/Contents/MacOS/AjazzControl"
/usr/bin/lipo -create "$staging/Spectrum-arm64" "$staging/Spectrum-x86_64" \
    -output "$app/Contents/Resources/Editor/Spectrum"
/usr/bin/codesign --force --sign - "$app/Contents/Resources/Editor/Spectrum"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ -e "$destination/ajazz-mac.app" ]]; then
    /usr/bin/ditto "$app" "$destination/ajazz-mac.app"
else
    mv "$app" "$destination/"
fi
printf '%s\n' "$destination/ajazz-mac.app"
