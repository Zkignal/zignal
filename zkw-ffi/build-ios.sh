#!/usr/bin/env bash
# Builds ZkwFFI.xcframework + Swift bindings for the iOS app.
# Run on the Mac:  ./build-ios.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Rust iOS targets"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

echo "==> Tests"
cargo test

echo "==> Build: iPhone, simulator, host (host is only for generating bindings)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
cargo build --release

echo "==> Generate Swift bindings"
rm -rf out && mkdir -p out/swift out/headers
cargo run --release --bin uniffi-bindgen -- generate \
  --library target/release/libzkw_ffi.dylib --language swift --out-dir out/swift

cp out/swift/zkw_ffiFFI.h out/headers/
cp out/swift/zkw_ffiFFI.modulemap out/headers/module.modulemap

echo "==> XCFramework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libzkw_ffi.a -headers out/headers \
  -library target/aarch64-apple-ios-sim/release/libzkw_ffi.a -headers out/headers \
  -output out/ZkwFFI.xcframework

echo
echo "Done. Add these two to the Xcode project:"
echo "  out/ZkwFFI.xcframework"
echo "  out/swift/zkw_ffi.swift"
