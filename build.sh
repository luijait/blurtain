#!/bin/sh
# Build Blurtain and install it to ~/Applications/Blurtain.app
set -e
cd "$(dirname "$0")"

swiftc -O main.swift detector.swift -o Blurtain \
    -framework AppKit -framework ScreenCaptureKit -framework Vision

APP="$HOME/Applications/Blurtain.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Blurtain "$APP/Contents/MacOS/"

# App icon: regenerate the .icns from assets/icon.png if missing.
if [ ! -f AppIcon.icns ] && [ -f assets/icon.png ]; then
    rm -rf Blurtain.iconset && mkdir Blurtain.iconset
    for s in 16 32 128 256 512; do
        sips -z $s $s assets/icon.png --out "Blurtain.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d assets/icon.png --out "Blurtain.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns Blurtain.iconset -o AppIcon.icns
    rm -rf Blurtain.iconset
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Blurtain</string>
<key>CFBundleIdentifier</key><string>dev.luijait.blurtain</string>
<key>CFBundleExecutable</key><string>Blurtain</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

# Prefer a stable signing identity if one exists (keeps the screen-recording
# permission across rebuilds); fall back to ad-hoc.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Blurtain\|Censor Signing"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep -oE '"[^"]+"' | head -1 | tr -d '"')
    codesign -s "$IDENTITY" --force "$APP"
else
    codesign -s - --force "$APP"
fi

echo "Installed: $APP"
