# Privacy

Effective November 22, 2026.

Zignal is a private messenger that sends messages inside shielded Zcash transactions. There
is no Zignal server and no Zignal account. We, the developer of Zignal, don't collect,
receive or store anything you type, send or keep in the app. Zignal is experimental and has
not been audited.

This page covers the Zignal iPhone app, the Zignal demo website, and Apple's TestFlight,
which delivers the app to testers.

## In short

| | |
|---|---|
| Account, phone number or email | None needed |
| Analytics, tracking, ads | None |
| Logs or crash reporting by Zignal | None (Apple's TestFlight sends crash reports; see below) |
| Where your data lives | On your phone, encrypted |
| What we can hand over if asked | Nothing from the app: we never have it |

## The app

**What stays on your phone**
- Your profiles, contacts, chats, keys and wallet. They're encrypted on the phone and kept
  out of iCloud and device backups.
- Your PINs. They open a vault kept in the Keychain for this phone only and sealed by the
  iPhone's Secure Enclave, so a copy taken off the phone can't be opened.
- Your 24-word recovery phrase. It is shown on the phone and never sent anywhere.

**What leaves your phone**
- **Messages:** each one goes out as an encrypted memo inside a shielded Zcash transaction.
  It is stored on the Zcash blockchain permanently and can't be deleted by anyone. Sender,
  recipient, amount and the message are hidden on chain. Your contact can read what you send
  them.
- **Wallet traffic:** the app talks only to the light server at the top of your server list
  (Network settings). The default servers are public and run by others, not by Zignal:
  zec.rocks, Stardust and Cake Wallet. You can use your own instead.

**What the server sees**
- **Tor off:** your IP address with every request: transactions you send, transactions it
  fetches for you, and blocks you download.
- **Tor on (the default for new profiles):** sending and fetching go through Tor, so the
  server sees a Tor exit instead of your IP address. Block downloads still connect directly,
  so the server learns that you use Zcash and when you sync. The Tor network's entry relay
  sees your IP address but not what you send.
- The README's [network privacy](README.md#network-privacy-tor-a-vpn-or-your-own-server)
  section explains this in detail, including how a VPN helps.

**Phone permissions**
- **Camera:** only to scan a contact's invite QR code on the New chat screen. Apple's scanner
  reads the code on the phone; no picture is saved or sent. You can paste the invite instead.
- **Pasteboard:** what you copy in Zignal stays on this phone (no Universal Clipboard) and
  expires after 60 seconds. Locking the app removes it sooner.
- Zignal doesn't ask for your contacts, photos, location, microphone or notifications.

## The demo website

- The demo is a static page that simulates the app. It sets no cookies, runs no analytics,
  loads nothing from other sites, and keeps nothing you type after a reload. It never asks
  for real PINs, recovery phrases or personal details.
- It is hosted on GitHub Pages. GitHub logs every visitor's IP address for security; see
  [GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)
  and GitHub's
  [privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## TestFlight

Testers get Zignal through Apple's TestFlight. Apple, not Zignal, runs it and shares some
data with us as the developer:
- for testers we invite by email: the name and email address used for the invitation (not
  shown for testers who join through a public link);
- your device model, iOS version and language, how many sessions and crashes the app had,
  and crash logs. Apple doesn't let testers turn this off;
- feedback and screenshots, only if you choose to send them, with some device details
  (carrier, time zone, connection type, battery and free space).

We use this only to fix and improve Zignal, and Apple doesn't allow us to share it with
anyone else. A crash log shows where in the app's code a crash happened; Zignal writes no
logs of its own. See Apple's
[TestFlight & Privacy](https://www.apple.com/legal/privacy/data/en/test-flight/) page for
what Apple collects.

## Children

Zignal is meant for people 13 and older. Where you live may set a higher age, for messaging
apps or for holding cryptocurrency. We don't knowingly collect data from anyone, children
included: the app sends us nothing.

## If you contact us

If you email zkchat@tuta.com or report an issue on GitHub, we receive your address or GitHub
account and what you write. We use it only to reply and fix problems.

## Changes

Changes to this page are listed in [CHANGELOG.md](CHANGELOG.md) and the repository's history.
The effective date above changes with each update.

## Contact

zkchat@tuta.com
