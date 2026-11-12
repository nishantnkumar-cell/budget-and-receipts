# Duo Budget privacy policy

Last updated: 12 November 2026

Duo Budget is a budgeting and receipts app for iPhone and Mac. It is built so that nobody but you, and the partner you choose to share with, can see your money.

## What we collect

Nothing. Duo Budget has no account, no servers of its own, no analytics, no advertising and no tracking. The developer never receives your data.

## Where your data is kept

- **On your devices.** Statements, payments, receipts, budgets and settings are stored in the app's own storage on your iPhone and Mac. They are left out of iCloud device backup, which is not end-to-end encrypted unless Advanced Data Protection is on, and so are files shared to the app while they wait to be read. Only the last four digits of account and card numbers are kept.
- **In your iCloud, end-to-end encrypted.** If iCloud sync is on (Settings › iCloud), your data is copied to your own private iCloud database. Every item, including receipt photos, is stored only in CloudKit encrypted fields, whose keys are kept in your iCloud Keychain. Apple cannot read them and neither can we. You can turn sync off at any time.
- **With your partner, if you invite them.** Household sharing uses an iCloud share that only the people you invite can join, and Duo Budget shows who sent an invitation and asks before you join anyone's household. Shared items stay end-to-end encrypted. Items you mark private are not shared, and neither are comments, history or rules about them.

## What runs on your device

- Receipts and statements are read on the device with Apple Vision.
- Categories, receipt corrections and Ask your budget use Apple Intelligence on the device. Nothing is sent to an AI service.
- Widgets receive only a small summary (safe to spend, what's left this month and the next bills, never individual payments). Their amounts are hidden while the device is locked, and you can turn amounts off entirely in Settings.
- Siri and Shortcuts answer budget questions only once your iPhone is unlocked, and not at all while the app lock is on.
- Reminders for bills and contracts are local notifications scheduled on the device.
- Face ID, Touch ID or your passcode can lock the app. The app only learns whether unlocking succeeded.

## Backup files

Settings › Backup can export your data to a `.duobackup` file, encrypted with AES-256-GCM using a key made from a password you choose. The file goes wherever you save it. Without the password nobody can open it, including us, and a lost password can't be recovered. CSV and PDF exports are not encrypted.

## The one optional online lookup

If you switch on **Look up unknown shops online** in Settings, the name and town of a shop the app doesn't recognise are sent to Apple Maps to find what kind of shop it is. Bank transfers, which usually name people rather than shops, are never looked up. This is off unless you turn it on. Apple's handling of Maps searches is covered by Apple's privacy policy.

## Permissions

- **Camera:** to scan receipts and contract documents.
- **Photos:** to read receipt photos you pick.
- **Face ID:** to unlock the app, if you turn on the app lock.
- **Notifications:** for bill, renewal and price-rise reminders, if you turn them on.

## Deleting your data

Settings › Erase All Data removes everything from the device, from your iCloud and from your other devices that sync. Deleting the app removes the data on that device. You can also remove the app's iCloud data in your device's iCloud settings.

## Children

Duo Budget is not directed at children.

## Open source

Duo Budget is open source under the MIT licence, so anyone can check these claims in the code: https://github.com/nishantnkumar-cell/budget-and-receipts

## Contact

Questions or problems: open an issue at https://github.com/nishantnkumar-cell/budget-and-receipts/issues

Changes to this policy are published in this file, with the date above updated.
