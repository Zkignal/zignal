#!/bin/bash
# Builds libzcashlc (this folder's Rust layer) for iPhone and for the iOS Simulator, and installs
# it in LocalPackages/, which Package.swift links. Zignal's version of upstream's
# `Scripts/init-local-ffi.sh --arm-ios`.
#
# Needs macOS with Xcode, and Rust 1.97 or newer with the iOS targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
# (on an Intel Mac, x86_64-apple-ios instead of aarch64-apple-ios-sim).
#
# Usage:  ./Scripts/build-ios-ffi.sh
# Replaces only build outputs: target/Headers/zcashlc.h and LocalPackages/.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_DIR="$(pwd -P)"

fail() { echo "build-ios-ffi: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "needs macOS with Xcode"
for tool in cargo rustup xcrun plutil shasum; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done

DEVICE_TARGET=aarch64-apple-ios
# hw.optional.arm64 is 1 on Apple silicon, even in a Terminal running under Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
  SIM_TARGET=aarch64-apple-ios-sim
  SIM_ARCH=arm64
else
  SIM_TARGET=x86_64-apple-ios
  SIM_ARCH=x86_64
fi
installed="$(rustup target list --installed)"
for t in "$DEVICE_TARGET" "$SIM_TARGET"; do
  grep -qx "$t" <<<"$installed" ||
    fail "the Rust target $t is missing. Run: rustup target add $DEVICE_TARGET $SIM_TARGET"
done

# The oldest iOS the library supports. It must not be newer than the app's minimum iOS (Zignal:
# 17.0), or the C parts (sqlite, zstd, secp256k1, ring) may use what older iOS versions lack.
# rustc and the C compiler both read this variable. Override it in the environment if needed.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

# Keep this Mac's file paths (which include the account name) out of the library, and so out of
# the app: rustc and the C compiler otherwise embed source paths in panic and assertion messages.
# When several rustc prefixes match, the last one given wins.
CARGO_DIR="${CARGO_HOME:-$HOME/.cargo}"
CARGO_ENCODED_RUSTFLAGS="$(printf '%s\037%s\037%s' \
  "--remap-path-prefix=$HOME=/build" \
  "--remap-path-prefix=$CARGO_DIR=/cargo" \
  "--remap-path-prefix=$SDK_DIR=/zcash-swift-wallet-sdk")"
export CARGO_ENCODED_RUSTFLAGS
export CFLAGS="-ffile-prefix-map=$HOME=/build"

# rust/build.rs writes the C header. cbindgen keeps an old header when it fails, so delete it and
# touch build.rs to make this build write it again.
HEADER=target/Headers/zcashlc.h
rm -f "$HEADER"
touch rust/build.rs

# One target at a time: each target runs rust/build.rs, and both runs write the same header file.
for t in "$DEVICE_TARGET" "$SIM_TARGET"; do
  echo "Building libzcashlc for $t, iOS $IPHONEOS_DEPLOYMENT_TARGET and later (release with LTO; the first build takes a while)"
  cargo build --release --locked --target "$t"
done

[ -s "$HEADER" ] || fail "the build didn't write $HEADER"
xcrun clang -fsyntax-only -x c "$HEADER" || fail "$HEADER doesn't compile as C"

needles=("$HOME")
account="$(id -un)"
[ "${#account}" -ge 4 ] && needles+=("$account")  # a very short name would match at random
for t in "$DEVICE_TARGET" "$SIM_TARGET"; do
  lib="target/$t/release/libzcashlc.a"
  [ -s "$lib" ] || fail "missing $lib"
  # The newest minimum iOS of any object in the library must not exceed the target above.
  newest="$(xcrun otool -l "$lib" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="minos"{split($2,v,"."); n=v[1]*1000+v[2]; if(n>m){m=n; s=$2} f=0} END{print s}' || true)"
  [ -n "$newest" ] || fail "couldn't read the minimum iOS version of $lib"
  awk -v a="$newest" -v b="$IPHONEOS_DEPLOYMENT_TARGET" 'BEGIN{split(a,x,".");split(b,y,"."); exit !((x[1]+0<y[1]+0)||(x[1]+0==y[1]+0 && x[2]+0<=y[2]+0))}' ||
    fail "$lib has code that needs iOS $newest, newer than iOS $IPHONEOS_DEPLOYMENT_TARGET"
  echo "$lib: needs iOS $newest or later"
  for needle in "${needles[@]}"; do
    n="$({ LC_ALL=C grep -a -o -F -- "$needle" "$lib" || true; } | wc -l | tr -d ' ')"
    [ "$n" = 0 ] || fail "$lib still contains this Mac's account name or home folder ($n times). Don't use or ship it."
  done
done

# Assemble the XCFramework next to the build, then swap it into LocalPackages/.
STAGE=target/xcframework-stage
XCF="$STAGE/libzcashlc.xcframework"
rm -rf "$STAGE"
add_slice() {  # $1 = Rust target, $2 = library identifier
  local fw="$XCF/$2/libzcashlc.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "target/$1/release/libzcashlc.a" "$fw/libzcashlc"
  cp "$HEADER" "$fw/Headers/zcashlc.h"
  cp BuildSupport/module.modulemap "$fw/Modules/module.modulemap"
  cp BuildSupport/platform-Info.plist "$fw/Info.plist"
}
add_slice "$DEVICE_TARGET" ios-arm64
add_slice "$SIM_TARGET" "ios-$SIM_ARCH-simulator"
cat > "$XCF/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>libzcashlc.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
		<dict>
			<key>LibraryIdentifier</key>
			<string>ios-$SIM_ARCH-simulator</string>
			<key>LibraryPath</key>
			<string>libzcashlc.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>$SIM_ARCH</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
plutil -lint "$XCF/Info.plist" >/dev/null || fail "the XCFramework's Info.plist is invalid"

mkdir -p LocalPackages
rm -rf LocalPackages/libzcashlc.xcframework
mv "$XCF" LocalPackages/libzcashlc.xcframework
rmdir "$STAGE"
cp BuildSupport/LocalPackages-Package.swift LocalPackages/Package.swift

echo
echo "Installed LocalPackages/libzcashlc.xcframework ($DEVICE_TARGET, $SIM_TARGET; iOS $IPHONEOS_DEPLOYMENT_TARGET and later)"
shasum -a 256 LocalPackages/libzcashlc.xcframework/*/libzcashlc.framework/libzcashlc "$HEADER"
