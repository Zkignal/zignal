#!/usr/bin/env bash
# Builds ZkwFFI.xcframework + Swift bindings and installs the bindings into the iOS app.
# Run on the Mac:  ./build-ios.sh        (works offline once dependencies are cached)
set -euo pipefail
cd "$(dirname "$0")"
APP_GEN="../ios/Zignal/Zignal/Generated"

echo "==> Rust iOS targets"
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> Tests"
cargo test --offline

echo "==> Build: iPhone, simulator, host (host is only for generating bindings)"
cargo build --offline --release --target aarch64-apple-ios
cargo build --offline --release --target aarch64-apple-ios-sim
cargo build --offline --release

echo "==> Generate Swift bindings"
rm -rf out && mkdir -p out/swift out/headers
cargo run --offline --release --bin uniffi-bindgen -- generate \
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
