#!/usr/bin/env bash
# Builds ZkwFFI.xcframework + Swift bindings and installs the bindings into the iOS app.
# Run on the Mac:  ./build-ios.sh        (works offline once dependencies are cached)
set -euo pipefail
cd "$(dirname "$0")"
APP_GEN="../ios/Zignal/Zignal/Generated"
REPO_DIR="$(cd .. && pwd)"

fail() { echo "build-ios.sh: $*" >&2; exit 1; }

echo "==> Rust iOS targets"
installed="$(rustup target list --installed)"
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  grep -qx "$t" <<<"$installed" || rustup target add "$t"
done

# Keep this Mac's file paths (which include the account name) out of the library, and so out of
# the app: rustc embeds source paths in panic messages, the C compiler in assertions.
# When several rustc prefixes match, the last one given wins.
CARGO_DIR="${CARGO_HOME:-$HOME/.cargo}"
CARGO_ENCODED_RUSTFLAGS="$(printf '%s\037%s\037%s' \
  "--remap-path-prefix=$HOME=/build" \
  "--remap-path-prefix=$CARGO_DIR=/cargo" \
  "--remap-path-prefix=$REPO_DIR=/zignal")"
export CARGO_ENCODED_RUSTFLAGS
export CFLAGS="-ffile-prefix-map=$HOME=/build"

# The oldest iOS the library supports, as in the SDK's build script: not newer than the app's
# minimum (17.0). rustc and the C compiler both read it. Override it in the environment if needed.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

echo "==> Tests"
cargo test --offline --locked

echo "==> Build: iPhone, simulator, host (host is only for generating bindings)"
cargo build --offline --locked --release --target aarch64-apple-ios
cargo build --offline --locked --release --target aarch64-apple-ios-sim
cargo build --offline --locked --release

echo "==> Identity check"
needles=("$HOME")
account="$(id -un)"
[ "${#account}" -ge 4 ] && needles+=("$account")  # a very short name would match at random
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  lib="target/$t/release/libzkw_ffi.a"
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
  echo "$lib: no home folder or account name"
done

echo "==> Generate Swift bindings"
rm -rf out && mkdir -p out/swift out/headers
cargo run --offline --locked --release --bin uniffi-bindgen -- generate \
  --library target/release/libzkw_ffi.dylib --language swift --out-dir out/swift
cp out/swift/zkw_ffiFFI.h out/headers/
cp out/swift/zkw_ffiFFI.modulemap out/headers/module.modulemap

echo "==> XCFramework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libzkw_ffi.a -headers out/headers \
  -library target/aarch64-apple-ios-sim/release/libzkw_ffi.a -headers out/headers \
  -output out/ZkwFFI.xcframework

echo "==> Install Swift bindings into the app"
mkdir -p "$APP_GEN"
cp out/swift/zkw_ffi.swift "$APP_GEN/zkw_ffi.swift"

echo
echo "Done."
echo "  Framework: zkw-ffi/out/ZkwFFI.xcframework  (link once in Xcode, Do Not Embed)"
echo "  Bindings:  ios/Zignal/Zignal/Generated/zkw_ffi.swift  (picked up automatically)"
