# zkw-ffi: Swift bindings for zkw-core
Not audited.

## Build (Mac, Terminal)
```bash
cd ~/Documents/Zignal/zkw-ffi
./build-ios.sh 2>&1 | tee build-output.txt
```
Produces `out/ZkwFFI.xcframework` and `out/swift/zkw_ffi.swift`.

## Swift API (what the app calls)
```swift
let inbox = try ZkwInbox(seed: seed32, now: UInt64(Date().timeIntervalSince1970))
let qr = try inbox.createInvite(myAddress: perContactUA)                 // show as QR
let out = try inbox.startFromInvite(invite: scanned, myAddress: ua, firstText: "hi")
// wallet: send out.memos as ONE shielded tx to out.toAddress
if let ev = try inbox.receive(memo: memo512, now: now) { /* switch on ev */ }
let vault = try vaultCreate(realPin:..., realSecret:..., duressPin:..., decoySecret:..., wipeRealOnDuress: false)
let u = try vaultUnlock(vault: vault, pin: entered)   // u.secret == nil -> wrong PIN
```

## Known gap (next core task)
Inbox state (sessions, prekeys, replay sets) lives in memory only. Before the
demo it needs `export`/`import` so chats survive an app restart. Sessions
already serialize; prekeys and the inbox wrapper do not yet.
