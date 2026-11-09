# Security policy

Zignal is experimental and has not been audited. It runs on Zcash mainnet, so use small
amounts.

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Either way works:

- **On GitHub:** open the repository's **Security** tab
  (https://github.com/Zkignal/zignal/security), click **Report a vulnerability** and fill in
  the form. Only you and the maintainers can see the report, and the whole conversation stays
  in one private place.
- **By email:** zkchat@tuta.com

Please include:
- the commit you looked at (`git rev-parse --short HEAD`);
- what an attacker can do, and what they need (for example a hostile contact, a hostile light
  server or a stolen phone);
- steps to reproduce, or a test that shows it;
- a suggested fix, if you have one.

We aim to acknowledge a report within 7 days. This is a small project, so a fix can take
longer: we'll keep you updated and agree on a disclosure date with you. Once a fix is out, we
publish an advisory and credit you, if you want.

## Scope

- `zkw-core/` (the Rust messaging core), `zkw-ffi/` (its Swift bindings), `zkw-ref/` (the
  Python reference) and the iOS app in `ios/Zignal/`.
- Zignal's changes to the Zcash Swift SDK in `vendor/zcash-swift-wallet-sdk/`, listed in its
  `ZIGNAL-PATCHES.md`.

Report bugs in librustzcash, the upstream Zcash Swift SDK, lightwalletd or Zebra to those
projects, and tell us too if they affect Zignal.

Fixes go to the `dev` branch. `main` is the Zecathon submission and stays as submitted until
judging ends.

## Known limitations

The README's [Security notes and known limitations](README.md#security-notes-and-known-limitations)
lists what Zignal doesn't protect against yet: for example, one 24-word phrase is both the
wallet seed and the messaging identity, Tor is off by default, and the fee shows how many
memos a transaction carries. Also known: the address inside an invite isn't signed, so a
tampered invite can block a chat (it can't read or forge messages). These aren't treated as
new vulnerabilities, unless you find a way to make them worse.

## Testing rules

Good-faith research is welcome. Please:
- test only with your own devices, wallets and funds;
- don't attack the public light servers or anyone else's addresses, and don't spam mainnet;
- don't access or keep other people's data;
- give us a reasonable chance to fix a problem before you talk about it publicly.
