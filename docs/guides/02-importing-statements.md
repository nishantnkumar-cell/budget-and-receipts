# Importing statements

Duo Budget doesn't connect to your bank. Instead, you download a statement from your bank's website or app and bring it in. The file is read on your device only.

## Supported files

- **CSV**, **OFX**, **QFX** and **QIF** exports from online banking.
- **PDF** statements, including HSBC. These are read on the device with Apple Vision.

## How to import

- **iPhone:** in your bank's app or Files, tap Share and choose **Duo Budget**. Or open Scan › Import a bank statement.
- **Mac:** drag the file onto the app, or use Scan › Import a bank statement. You can also share a file to Duo Budget from Finder.

The bank and account are read from the statement itself. For a CSV file, the import screen shows a preview and lets you check the columns (one amount column, or separate paid out and paid in columns), the date style (3 October UK or 10 March US) and a decimal comma (12,50). Card statements that list purchases as positive amounts are turned round automatically.

Importing the same statement twice is safe: payments that are already there are not added again.

## Bank accounts

Each payment belongs to an account, so spending is kept apart per account and card.

- OFX and QFX files, and CSV files with an account column, carry the account number. New accounts are added for you and named "Account ••1234". Only the last four digits are ever shown.
- For files without one, the import screen asks which account it's for.
- In **Settings › Bank accounts** you can rename accounts (for example "Joint current account"), say whose account it is (mine, partner's or joint), mark one private, and add the **last four digits of your cards**. Receipts showing a card ending are then only matched to that account.
- Once you have two accounts, Home and Activity show an account menu, and Home shows spending by account.

### Whose account is it?

For a PDF statement, the account holder's name on the statement is matched against the names in Settings › Couple, so your partner's statement becomes your partner's account and a statement in both names becomes a joint account. CSV, OFX and QIF files carry no names, so set the owner in Settings › Bank accounts. An owner you set by hand is never changed by the app.

## Categories

New payments are sorted into categories by your rules, the app's 50 starter rules for common shops, and, if you allow it, Apple Intelligence on the device. An indicator shows while this is happening. Anything it isn't sure about appears in **To Check**. Tap **Categorise with AI** there to sort the rest at once.

Optionally, Settings › Categories › **Look up unknown shops online** asks Apple Maps what kind of business a shop is, sending only the shop's name and town.

A payment's own category always wins: change it, and the app learns from it. See [Budgets and categories](04-budgets.md) for rules.

## Words on statements

- **OBP** means online banking payment: a transfer to one of your own accounts, not spending.
- Transfers between your own accounts and card repayments are kept out of your spending totals.

## Logging Apple Pay as you go

You can also have each Apple Pay payment appear straight away, before the statement arrives. See [Widgets, Siri and Ask your budget](09-widgets-siri-ask.md#log-apple-pay-payments).
