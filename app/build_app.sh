#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(cd "$ROOT/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
CACHE="/tmp/livephoto-swiftcache"

mkdir -p "$CACHE" "$WORK/dist"
rm -rf "$WORK/dist/光影间.app" "$WORK/dist/arm64" "$WORK/dist/x86_64"

export TMPDIR=/tmp
export SWIFT_MODULE_CACHE_PATH="$CACHE"
export CLANG_MODULE_CACHE_PATH="$CACHE"

build_arch() {
    local ARCH="$1"
    local TARGET="$2"
    local ARCH_DIR="$WORK/dist/$ARCH"
    local APP="$ARCH_DIR/光影间.app"
    local ZIP="$WORK/dist/光影间-$VERSION-$ARCH.zip"

    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    swiftc -parse-as-library -O \
        -module-cache-path "$CACHE" \
        -target "$TARGET" \
        -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO \
        "$ROOT/Sources/"*.swift \
        -o "$APP/Contents/MacOS/LivePhotoConverter"

    cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
    for lproj in "$ROOT/Resources/"*.lproj; do
        [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
    done
    cp "$WORK/android2apple.py" "$APP/Contents/Resources/android2apple.py"

    if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
        cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    fi
    for icon in AppIconLight.png AppIconDark.png; do
        if [ -f "$ROOT/Resources/$icon" ]; then
            cp "$ROOT/Resources/$icon" "$APP/Contents/Resources/$icon"
        fi
    done

    if [ -d "$ROOT/vendor/exiftool" ]; then
        cp -R "$ROOT/vendor/exiftool" "$APP/Contents/Resources/exiftool"
        chmod +x "$APP/Contents/Resources/exiftool/exiftool"
    fi

    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "built ($ARCH): $APP"
    echo "packaged ($ARCH): $ZIP"
}

build_arch "arm64" "arm64-apple-macosx13.0"
build_arch "x86_64" "x86_64-apple-macosx13.0"
