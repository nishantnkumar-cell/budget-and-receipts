# Returns, warranties and encrypted backups

## Returns and warranties (`Core/ProductCovers.swift`, `CoverViews.swift`)
- `ProductCover`: item, shop, date bought, price, return-by date, warranty end, the payment it's linked to,
  the receipt photo's file name, a note, returned, private. Stored in `covers.json`, synced as collection
  `covers` (private when marked); the linked receipt photo keeps syncing even after the split is approved.
- Added from the receipt check screen (Mac and iPhone), a payment's editor, or Plan › Returns and
  warranties, with quick picks (14–90 days to return, 1–5 years of warranty). Edit and delete everywhere.
- `CoverWatch` flags a return closing within 7 days (red within 3) and a warranty ending within 30 days.
- Reminders reuse the contract reminders (`ReminderPlanner`, `ReminderScheduler`): new kinds `returnBy`
  (3 days before, 9am) and `warrantyEnds` (30 days before). With the app lock on, the lock screen text
  stays generic.

## Encrypted backup (`EncryptedBackup.swift`, `BackupViews.swift`)
- Settings › Backup › Export Encrypted Backup: every data file (the app's JSON files, receipt photos and
  contract documents) in one `.duobackup` file. iCloud connection files (`sync-*`, `household.json`) and
  per-device settings are left out.
- Format: `DUOBACKUP1`, a 16-byte random salt, the PBKDF2-SHA256 round count (600,000), then an AES-256-GCM
  sealed box of the LZFSE-compressed archive (manifest + files). The header is authenticated too. The
  password (8+ characters) can't be recovered.
- Restore: choose the file and enter the password; nothing changes until you've seen what's in it (date,
  device, payments, budgets, contracts, photos). "Replace Everything With This Backup…" asks again in a
  destructive confirmation, then for Face ID / Touch ID / the passcode. Files are written to a staging
  folder first, so a failure leaves the current data alone; then the data is replaced exactly, the stores
  reload, and iCloud sync makes the other devices match. Paths in a backup are checked, so a crafted file
  can't write outside the data folder.
- The Mac app's sandbox now allows read-write on files you choose, so exports can be saved.
