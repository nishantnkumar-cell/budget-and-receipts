Duo Budget is designed so that only you, and the partner you choose to share with, can see your money. This page is the short version. The full [privacy policy](https://github.com/nishantnkumar-cell/budget-and-receipts/blob/main/docs/PRIVACY.md) is in the repository.

## No account and no tracking

You don't sign up for anything. The app has no servers of its own, no analytics and no ads, and the developer never sees your data.

## Where your data is kept

- On your devices, in the app's own storage. It isn't included in normal iCloud device backups.
- In your own iCloud, if you turn sync on. Everything, receipt photos included, is stored in encrypted fields whose keys are in your iCloud Keychain. Apple can't read it.
- On your partner's devices, if you invite them. The shared household is encrypted end to end too, and private items aren't shared.
- In backup files you make yourself, locked with your password (see [Backups and erasing data](Backups-and-erasing-data)).

## What runs on your device

- Receipts and PDF statements are read on the device.
- Categories, receipt clean-up and Ask your budget use Apple Intelligence on the device. Nothing is sent to an online AI service.
- Reminders are set up on the device.
- Widgets only get a short summary (safe to spend, what's left and the next few bills), never your individual payments. They hide the amounts while the device is locked.

## The one thing that can go online

Settings > Categories > Look up unknown shops online is off until you turn it on. When it's on, the name and town of a shop the app doesn't know are sent to Apple Maps. Amounts and dates are never sent.

## Locking the app

Settings > Privacy > Lock with Face ID (or Touch ID or passcode) asks you to unlock each time the app opens. The app only finds out whether unlocking worked.

## You can check

The app is open source, so anyone can read the code and check all of this: https://github.com/nishantnkumar-cell/budget-and-receipts
