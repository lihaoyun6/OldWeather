#!/bin/sh
# Build OldWeather_v<ver>_iphoneos-arm.deb (armv6 + armv7) with no Python.
#
#   ./build.sh                       build
#   ./build.sh clean                 remove build/ and dist/
#   SDK=/path/to/sdk ./build.sh      use another iPhoneOS3.1.3.sdk
#
# Requires: Xcode command line tools (clang, lipo, tar, gzip), ldid.

set -e

PKG=com.lihaoyun6.oldweather
VER=1.0.0
ARCH=iphoneos-arm
NAME=OldWeather_v${VER}_${ARCH}.deb

SDK=${SDK:-$TMPDIR/sdk/iPhoneOS3.1.3.sdk}
BUILD=build
DIST=dist
CLANG=$(xcrun -f clang)

if [ "$1" = "clean" ]; then
    rm -rf "$BUILD" "$DIST"
    echo "cleaned"
    exit 0
fi

if [ ! -f "$SDK/System/Library/Frameworks/Foundation.framework/Headers/Foundation.h" ]; then
    echo "error: iPhoneOS3.1.3.sdk not found at $SDK" >&2
    echo "       run: SDK=/path/to/iPhoneOS3.1.3.sdk ./build.sh" >&2
    exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/root/Library/MobileSubstrate/DynamicLibraries" "$BUILD/DEBIAN" "$DIST"

FLAGS="-isysroot $SDK -dynamiclib -fno-objc-arc -O2 -fno-stack-protector"
LIBS="-framework Foundation -lobjc -lSystem -Wl,-undefined,dynamic_lookup"

echo "==> armv6"
"$CLANG" -target armv6-apple-ios3.1.3 $FLAGS -o "$BUILD/armv6.dylib" plugin/WeatherDGW.m $LIBS

echo "==> armv7"
"$CLANG" -target armv7-apple-ios3.1.3 $FLAGS -o "$BUILD/armv7.dylib" plugin/WeatherDGW.m $LIBS

echo "==> universal + sign"
lipo -create "$BUILD/armv6.dylib" "$BUILD/armv7.dylib" -output "$BUILD/WeatherDGW.dylib"
ldid -S "$BUILD/WeatherDGW.dylib"

install -m 755 "$BUILD/WeatherDGW.dylib" \
    "$BUILD/root/Library/MobileSubstrate/DynamicLibraries/WeatherDGW.dylib"
install -m 644 plugin/WeatherDGW.plist \
    "$BUILD/root/Library/MobileSubstrate/DynamicLibraries/WeatherDGW.plist"
install -m 644 debian/control "$BUILD/DEBIAN/control"
install -m 755 debian/postinst "$BUILD/DEBIAN/postinst"
install -m 755 debian/prerm "$BUILD/DEBIAN/prerm"

echo "==> control.tar.gz / data.tar.gz"
tar --format ustar -cf - -C "$BUILD/DEBIAN" . | gzip -9n > "$BUILD/control.tar.gz"
tar --format ustar -cf - -C "$BUILD/root" . | gzip -9n > "$BUILD/data.tar.gz"

# dpkg 1.14 reads a plain ar container; write the 60-byte headers by hand so
# no ar implementation can add symbol tables or GNU long-name members.
make_ar() {
    out=$1
    shift
    printf '!<arch>\n' > "$out"
    for f in "$@"; do
        size=$(wc -c < "$f" | tr -d ' ')
        hdr=$(printf '%-16s%-12s%-6s%-6s%-8s%-10s' \
              "$(basename "$f")/" 1356998400 0 0 100644 "$size")
        printf '%s`\n' "$hdr" >> "$out"
        cat "$f" >> "$out"
        if [ $((size % 2)) -ne 0 ]; then
            printf '\n' >> "$out"
        fi
    done
}

echo "==> deb"
printf '2.0\n' > "$BUILD/debian-binary"
make_ar "$DIST/$NAME" \
    "$BUILD/debian-binary" "$BUILD/control.tar.gz" "$BUILD/data.tar.gz"

rm -rf "$BUILD"
echo "==> built $DIST/$NAME"
ls -l "$DIST/$NAME"
file "$DIST/$NAME"
