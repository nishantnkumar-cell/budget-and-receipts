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

## Step 2: sharing with a partner (next)

- Share the Household zone with a `CKShare`. You send an invite, your partner accepts on their iPhone, and their app reads and writes the shared zone through their shared database.
- Their own private items stay in their own Private zone.
- Who owes whom, Mine / Partner / Shared and settle-ups already work on shared data.
