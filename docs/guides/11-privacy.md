# Privacy and encryption

Duo Budget is built so that nobody but you, and the partner you choose, can see your money. The full privacy policy is in [PRIVACY.md](../PRIVACY.md); this is the short version.

## No account, no servers, no tracking

There's no Duo Budget account to sign up for. The app has no servers of its own, no analytics and no adverts. The developer never receives your data.

## Where your data is

- **On your devices**, in the app's own storage. It's left out of normal iCloud device backups.
- **In your own iCloud, end-to-end encrypted**, if you turn on sync. Every item, including receipt photos, is stored in encrypted fields whose keys are in your iCloud Keychain. Apple can't read it.
- **With your partner**, if you invite them. The household share stays end-to-end encrypted, and private items aren't shared.
- **In backup files you make**, encrypted with your password (see [Backups](10-backups.md)).

## What happens on your device

- Receipts and PDF statements are read with Apple Vision on the device.
- Categories, receipt tidy-up and Ask your budget use Apple Intelligence on the device. Nothing goes to a cloud AI service.
- Reminders are scheduled on the device.
- Widgets get only a small summary (safe to spend, what's left and the next bills, never your payments), and hide amounts while the device is locked.

## The one optional online lookup

Settings › Categories › **Look up unknown shops online** is off unless you turn it on. It sends only a shop's name and town to Apple Maps, never amounts or dates.

## Locking the app

Settings › Privacy › **Lock with Face ID** (or Touch ID or passcode) asks to unlock each time the app opens. The app only learns whether unlocking worked.

## Open source

The app is open source, so anyone can check these promises in the code: https://github.com/nishantnkumar-cell/budget-and-receipts
