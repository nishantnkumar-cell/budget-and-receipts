# iCloud sync and sharing with a partner

## Decisions (Nishant, 2026-11-02)

- Data is shared with the partner **by default**. An item is hidden only when it is marked **Private**.
- Sync uses Apple's iCloud (CloudKit). There is no server of our own. Each person uses their own Apple ID.

## Step 1: your own devices (this change)

- Everything is stored in your **private iCloud database** in container `iCloud.com.nishantkumar.budgetreceipts`, in two zones (now `HouseholdE2E` and `PrivateE2E`, see below):
  - **Household**: everything not marked private. In step 2 this zone is shared with the partner.
  - **Private**: items marked private, and transactions in an account marked private. It is never shared.
- Each item (transaction, budget, waiting receipt, account, contract, settle-up and so on) is one iCloud record holding the item's JSON (`SyncRecord`).
- **End-to-end encrypted** (Nishant, 2026-11-02: no unencrypted data in iCloud). The item's collection, id and JSON, and any receipt photo, are stored only in CloudKit `encryptedValues`. Their keys live in the user's iCloud Keychain, so Apple can't read them even without Advanced Data Protection, and CloudKit gives them to share participants. Photos are shrunk to at most 700 KB so they fit in a record. Record names are a SHA-256 hash of the item's key, so no dates, amounts or names show in plain text. Zones are `HouseholdE2E` and `PrivateE2E`. The first version's plain-field zones (`Household`, `Private`) are deleted on upgrade and everything is re-sent encrypted; local data is untouched.
- Only changes are sent. `SyncState` remembers a fingerprint of each item as last synced. Marking an item private moves it from the Household zone to the Private zone.
- `CKSyncEngine` handles scheduling, retries and push notifications. Changes from other devices are applied on arrival and when the app comes to the front. On a save conflict the device re-sends its own copy with the newer change tag, so the last edit wins.
- Signing out of iCloud or switching Apple ID resets what was sent, and everything is sent again under the new account.
- Settings › iCloud › Sync with iCloud turns it off. Builds without iCloud (tests, or the Mac until it is registered) leave it off.

## Step 2: sharing with a partner

- The owner taps Settings › Partner › Invite your partner. That shares the `HouseholdE2E` zone with a `CKShare` (zone-wide, read-write, by invitation only). The partner opens the link; the app accepts it (`ShareAcceptor`) and syncs the owner's zone through the shared database. Their own `HouseholdE2E` zone is removed and their shared items move into the owner's zone. `PrivateE2E` stays in each person's own private database.
- Shared data is stored from the owner's point of view. The partner's app flips Mine/Partner, who paid, settle-ups and the couple split as records arrive and back as they leave (`HouseholdPerspective`), so "Mine" means you on each phone.
- Protections (security review F3): anything changed or deleted by another device or the partner is kept 30 days in Settings › Partner › Recently changed, with Restore. The owner's device refuses partner edits to the couple settings and the owner's accounts and re-sends its own. Leaving or stopping sharing keeps each person's data; copies already shared can't be recalled.

## Safety (security review)

- An unreadable local file is set aside and the next sync restores from iCloud instead of sending deletions (F2). More than 25 deletions at once, or a fifth of everything, are held until the person confirms or restores (Settings › iCloud). Erase All Data is the one deliberate exception.
- Changes from iCloud count as synced only once saved to disk. Files stay writable while the iPhone is locked (F4).
- App data is left out of iCloud device Backup, which isn't end-to-end encrypted (F1). Record names are random (F9). Photo names from iCloud must be the app's own (F13), and photos are re-encoded without metadata (F11).
- The first version's plain zones are deleted on every launch (F5). Sync only starts when the provisioning profile grants the iCloud container, otherwise CloudKit would stop the app.
