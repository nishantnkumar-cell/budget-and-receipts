Duo Budget doesn't log in to your bank. You download a statement from your bank and open it in the app. It's read on your device and never uploaded.

## What files work

CSV, OFX, QFX and QIF exports from online banking all work, and so do PDF statements (HSBC's included). PDFs are read with Apple's text recognition on the device.

## Bringing a statement in

On iPhone, open the statement in your bank's app or in Files, tap Share and pick Duo Budget. You can also go to Scan > Import a bank statement.

On the Mac, drag the file onto the app window, share it from Finder, or use Scan > Import a bank statement.

The app works out the bank and account from the statement. For a CSV file you'll see a preview first. Check that the columns look right (some banks use one amount column, others use separate money in and money out columns), that the dates are read the right way round, and whether the file uses a comma for pence (12,50). Card statements that list purchases as positive numbers are flipped for you.

You can import the same statement twice without worrying. Payments that are already there are skipped.

## Accounts and cards

Each payment belongs to an account, so you can see what went out of each one.

OFX and QFX files, and CSV files with an account column, include the account number, so new accounts are added for you. They start out with names like "Account ••1234". The app only ever shows the last four digits. If a file has no account number, the app asks which account it belongs to.

In Settings > Bank accounts you can:

- rename an account, for example "Joint current account"
- say whose it is: yours, your partner's or joint
- mark it private
- add the last four digits of the cards on that account, so a receipt paid with that card is only matched to that account

Once you have two or more accounts, Home and Activity get an account filter, and Home shows how much went out of each.

### Whose account is it?

On a PDF statement, the app reads the account holder's name and compares it with the names in Settings > Couple. Your partner's statement becomes their account, and a statement in both names becomes a joint account. CSV, OFX and QIF files don't include names, so set the owner yourself in Settings > Bank accounts. If you pick the owner by hand, the app won't change it.

## Categories

New payments are sorted using your own rules, about 50 built-in rules for common shops and, if you allow it, Apple Intelligence running on your device. You'll see a small indicator while it's working. Anything it can't place goes to To Check, where Categorise with AI sorts the rest in one go.

There's also an optional setting, Settings > Categories > Look up unknown shops online. It asks Apple Maps what kind of business a shop is. Only the shop's name and town are sent.

If you change a payment's category, your choice sticks. See [Budgets and categories](Budgets-and-categories) for setting up rules.

## A few things on statements

OBP stands for online banking payment. It's a transfer to another of your own accounts, so it doesn't count as spending. Card repayments and transfers between your accounts are left out of spending too.

## Apple Pay as it happens

If you'd rather see Apple Pay payments straight away instead of waiting for the statement, see [Log Apple Pay payments](Widgets-Siri-and-Ask-your-budget#log-apple-pay-payments).
