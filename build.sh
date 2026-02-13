#!/bin/bash
set -e

APP_NAME="Clockoo"
APP_BUNDLE="$APP_NAME.app"
BUNDLE_ID="com.clockoo"
BUILD_DIR=".build"

echo "Building $APP_NAME..."
swift build

echo "Creating $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy icon
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Codesign — use developer identity if available, otherwise ad-hoc
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
    echo "   Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP_BUNDLE"
    echo "   Signed with: ad-hoc"
fi

echo "✅ Built $APP_BUNDLE"
echo "   Run: open $APP_BUNDLE"
echo "   Or:  $APP_BUNDLE/Contents/MacOS/$APP_NAME"
