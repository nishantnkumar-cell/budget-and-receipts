# Widgets, Control Centre, Siri and Ask your budget

## Widgets (`Apple/Widgets`, targets Widgets-iOS and Widgets-macOS)
- **Safe to spend** (small; Lock Screen rectangular, inline, circular on iPhone) and **Next bill** (small,
  medium; Lock Screen on iPhone).
- Widgets can't read the app's files, so after every save (`BudgetStore.didChange`, contract changes and
  coming to the front) `WidgetBridge` writes `widget-snapshot.json` into the App Group: this month's safe to
  spend for the whole household, what's left, bills still to come, and the next five bills. No payments.
- Settings › Show amounts in widgets off writes no figures at all. Amounts are `privacySensitive`, so they're
  hidden on a locked device.
- Tapping opens `duobudget://budgets` or `duobudget://plan` (`AppNavigator`).

## Control Centre
- `ScanReceiptControl` (iPhone): a Control Centre, Lock Screen or Action button control running
  `OpenScanIntent`, which opens `duobudget://scan`. The same intent is "Scan a receipt with Duo Budget" in Siri.

## App Intents (`BudgetIntents.swift`)
- **Budget Left** (optional category): what's left this month and the safe daily amount after bills.
- **Log a Payment** (amount, merchant, card): for a Shortcuts automation on Wallet › Apple Pay. It adds a
  payment with a `logged:` fingerprint, categorised like any other. `LoggedPaymentMatcher` joins it to its
  statement line on import (or when the line arrives from another device): the same amount (or, logged in
  another currency, the same shop), from a day before to six days after, the card's account when known.
  With two possible lines the shop name decides; otherwise it waits under Possible copies. The statement's
  date, amount and wording are kept, plus what you added (category, tags, owner, notes, receipt).
- **Ask Your Budget** (question).
- Siri phrases in `DuoBudgetShortcuts`.

## Ask your budget (`BudgetAssistant`, `Core/BudgetQuestions.swift`)
- `BudgetFacts` works out every figure exactly (month totals, categories with budgets and last month, shops,
  safe to spend, bills). Apple's on-device model (Foundation Models) only words an answer from that sheet,
  told to copy amounts as written. "Can I afford £50?" is worked out in code, never by the model.
- No cloud AI. Without Apple Intelligence (or with Settings › Answer questions with Apple Intelligence off),
  `simpleAnswer` handles categories, shops, what's left, bills and spending.
- Opens from the sparkles button on Home (iPhone) and the Mac toolbar, or `duobudget://ask`.
