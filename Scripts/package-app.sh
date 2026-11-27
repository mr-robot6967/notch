#!/bin/bash
# Build Notch.app (universal arm64 + x86_64 when possible, signed, with icon) in the repo root.
#   ARCHS="arm64" Scripts/package-app.sh   # build only one architecture (faster)
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

# Artwork: regenerate when missing or when the drawing script changed.
if [ ! -f Resources/AppIcon.icns ] || [ Scripts/make-art.swift -nt Resources/AppIcon.icns ]; then
    echo "Drawing icon and DMG artwork..."
    swift Scripts/make-art.swift Resources
    ICONSET=Resources/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
    rm -rf "$ICONSET"
fi

# One release build per architecture, then lipo them together so the app also runs on Intel Macs.
# Newer SwiftPM writes every architecture to the same output folder, so each binary is copied out
# straight after its build. An architecture that fails to build is skipped (with a warning).
ARCHS="${ARCHS:-arm64 x86_64}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SLICES=()
for arch in $ARCHS; do
    echo "Building release binary ($arch)..."
    BIN_PATH=$(swift build -c release --arch "$arch" --show-bin-path)
    # A failed build used to leave the previous binary in place, which was then packaged as if new:
    # remove it first and check the build's own exit status (not grep's).
    rm -f "$BIN_PATH/LockWidgets"
    BUILD_OK=1
    swift build -c release --arch "$arch" >"$WORK/build-$arch.log" 2>&1 || BUILD_OK=0
    grep -v -e "ld: warning" -e "x86_64 architecture is deprecated" "$WORK/build-$arch.log" || true
    if [ "$BUILD_OK" = 1 ] && [ -x "$BIN_PATH/LockWidgets" ] && lipo "$BIN_PATH/LockWidgets" -verify_arch "$arch" 2>/dev/null; then
        cp "$BIN_PATH/LockWidgets" "$WORK/LockWidgets-$arch"
        SLICES+=("$WORK/LockWidgets-$arch")
    else
        echo "warning: $arch build failed; leaving it out of the app" >&2
    fi
done
[ ${#SLICES[@]} -gt 0 ] || { echo "Build failed"; exit 1; }
lipo -create "${SLICES[@]}" -output "$WORK/Notch"
BUILT_ARCHS=$(lipo -archs "$WORK/Notch")

APP="Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/Notch" "$APP/Contents/MacOS/Notch"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/lock.caf Resources/unlock.caf "$APP/Contents/Resources/"

# The helper is loaded into /usr/bin/perl, which runs natively (arm64 or x86_64), so it needs
# the same slices as the app.
echo "Building Now Playing helper..."
HELPER_ARCHS=()
for arch in $BUILT_ARCHS; do HELPER_ARCHS+=(-arch "$arch"); done
clang -dynamiclib -fobjc-arc -O2 "${HELPER_ARCHS[@]}" -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit \
    -o "$APP/Contents/Resources/LWMediaRemote.dylib" Helpers/mediaremote/lwmr.m
cp Helpers/mediaremote/lwmr.pl "$APP/Contents/Resources/lwmr.pl"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Prefer the stable local identity (Scripts/create-signing-cert.sh) so macOS keeps permissions
# such as Full Disk Access and Accessibility across rebuilds. On any other Mac that identity
# doesn't exist, so fall back to ad-hoc signing automatically. `find-identity -p codesigning`
# lists only identities that can sign (certificate + private key); no `-v`, because a
# self-signed certificate is reported as "not trusted" yet signs fine.
IDENTITY="LockWidgets Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Signing with \"$IDENTITY\"..."
    SIGN=(--sign "$IDENTITY")
else
    echo "Ad-hoc signing (run Scripts/create-signing-cert.sh for permissions that survive rebuilds)..."
    SIGN=(--sign - --requirements '=designated => identifier "com.k2a.LockWidgets"')
fi
# --deep does not sign code inside Resources, so sign the helper dylib explicitly first.
codesign --force --sign "${SIGN[1]}" "$APP/Contents/Resources/LWMediaRemote.dylib"
codesign --force --deep "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "Packaged $DIR/$APP ($BUILT_ARCHS)"
