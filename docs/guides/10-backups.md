# Backups and starting again

Your data is kept out of the iPhone's and Mac's normal device backups, because those aren't always end-to-end encrypted. iCloud sync keeps a copy on your other devices, but it isn't a backup: a deletion syncs too. So make an encrypted backup file now and then.

## Make an encrypted backup

1. Settings › Backup › **Export Encrypted Backup**.
2. Choose a password of at least 8 characters. **Write it down somewhere safe: it can't be recovered**, by you or anyone else.
3. Save the `.duobackup` file somewhere you trust, such as Files, an external drive or another cloud.

The file holds every payment, budget, goal, contract, rule, receipt photo and contract document, encrypted with AES-256 using a key made from your password. Without the password it can't be opened.

## Restore from a backup

1. Settings › Backup › **Restore From Backup…**, choose the file, enter the password and tap **Open Backup**.
2. The app shows what's in it (when it was made, on which device, and how many payments, budgets, contracts and photos). Nothing has changed yet.
3. Tap **Replace Everything With This Backup…**, confirm, and unlock with Face ID, Touch ID or your passcode.

Your current data is **replaced** by the backup. If anything goes wrong part way, your current data is left as it was. After a restore, iCloud sync makes your other devices match.

## Other exports

Settings › Export has **Export All Transactions (CSV)**, for a spreadsheet, and a PDF report for the month. These are not encrypted.

## Erase all data

Settings › Start again › **Erase All Data…** deletes every payment, budget, receipt, account, contract and shared file on this device, on your other devices that sync, and the shared household items on your partner's devices (they can restore them for 30 days). Your settings are kept.

It asks for Face ID or your passcode, then for you to type **ERASE**. It can't be undone, so make a backup first.

If sync ever notices that a very large number of items vanished at once, it pauses in case something went wrong, and offers **Restore from iCloud**.
