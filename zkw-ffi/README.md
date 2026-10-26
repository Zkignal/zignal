# zkw-ffi: Swift bindings for zkw-core

Not audited. Builds `zkw-core` for iOS and generates its Swift API with UniFFI.

## Build (macOS)

```bash
./build-ios.sh
```

The script:
1. Runs the binding tests.
2. Builds for iOS devices and the simulator.
3. Produces `out/ZkwFFI.xcframework`.
4. Copies the generated `zkw_ffi.swift` into `../ios/Zignal/Zignal/Generated/`.

The app links the framework statically (Do Not Embed).

## Swift API (what the app calls)

```swift
// Profiles: the real and decoy secrets in one three-slot vault. The duress PIN opens the
// decoy; the panic PIN opens the decoy and silently wipes the real slot.
let vault = try vaultCreate(realPin: real, realSecret: s1, duressPin: duress, decoySecret: s2,
                            panicPin: panic)
let opened = try vaultUnlock(vault: vault, pin: entered)   // opened.secret == nil -> wrong PIN
// Always store opened.vault: it differs from `vault` only after a silent wipe.
let keys = try profileKeys(profileSecret: secret)          // identitySeed + stateKey

// Inbox: create, save after every change, restore after an app restart
let inbox = try ZkwInbox(seed: keys.identitySeed, now: now)
let saved = try inbox.exportSealed(stateKey: keys.stateKey)
let restored = try ZkwInbox.restore(identitySeed: keys.identitySeed, stateKey: keys.stateKey,
                                    sealedState: saved)

// Contacts and messages
let invite = try inbox.createInvite(myAddress: perContactAddress)      // show as QR / link
let out = try inbox.startFromInvite(invite: scanned, myAddress: ua, firstText: "hi")
// wallet: send out.memos as ONE shielded transaction to out.toAddress
if let event = try inbox.receive(memo: memo512, now: now) { /* switch on event */ }
```
