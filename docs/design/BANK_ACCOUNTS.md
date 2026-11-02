# Bank accounts

Money can come from several accounts and cards (a current account, a joint account, a credit card). Each transaction can belong to one `BankAccount`.

## Which account a statement is from

- **OFX and QFX** files carry the account number (`<ACCTID>`).
- **CSV** files with an "Account" (or "Account number") column can hold several accounts in one file.
- Otherwise the import screen asks: pick an account, add a new one, or leave it with no account. A statement shared from another app with no number in it is imported with no account; set it on the transactions or in Settings.
- Accounts are recognised by the last four digits of the number. A new number becomes a new account ("Account ••1234") when the import is confirmed, and can be renamed in Settings › Bank accounts. Only the last four digits are ever shown.

## Duplicates

Each transaction's fingerprint includes its account, so the same coffee on the same day in two accounts is two payments. Lines imported before accounts existed (no account) are still recognised, so re-importing an old statement into an account adds nothing.

## Seeing money per account

- Home and Activity have an account menu (shown once there are two accounts). It filters Activity, and the Home and Budgets totals follow it.
- Home shows "Spending by account" for the month. Tap an account to filter to it.
- A transaction's account can be changed in its editor.

## Receipts

In Settings, each account can list the last four digits of its cards. When a receipt prints a masked card number ("VISA ****1234"), only payments from that card's account are matched automatically. Where two payments are otherwise equal, the account is the tie-break.
