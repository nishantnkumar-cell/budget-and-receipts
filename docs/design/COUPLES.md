# Couples (Phase 2)

The app works for one person by default. Adding a partner's name in Settings › Couple turns on the couples features.

## Whose money

Every transaction, receipt split and receipt item can be **Mine**, **Partner** or **Shared**. When nothing is set by hand, the owner comes from the rules, in this order:

1. The owner set on the transaction (or on a split or receipt item, which otherwise follows its transaction).
2. The first merchant rule whose text appears in the merchant name (ignoring case and accents).
3. The first category rule for the transaction's category.
4. The default owner (Mine unless changed).

Merchant rules win over category rules because they are more specific: "Netflix is mine" beats "Subscriptions are shared".

## Shares

Shared costs split by "your share", 50% by default. `CoupleSettings.share(myIncome:partnerIncome:)` gives an income-based split, e.g. 3,000 and 2,000 gives 60/40.

The Me / Partner / Together switch scales spending to each view: Me counts mine plus my share of shared, Partner the reverse, Together everything. Budgets and reports use the scaled transactions (`CoupleLedger.transactions(_:for:)`), so rollover follows the view too.

## Who owes whom

Statements come from my accounts, so the payer is me unless a transaction says the partner paid. Whoever paid is owed the other person's share of each purchase; a refund reverses it. Income and transfers between accounts are never shared. Settlements ("Sam paid me back") reduce the balance. The balance is kept exact and rounded to the penny (banker's rounding) only for display and settling.

Code: `Core/Sources/BudgetCore/Couples.swift`, tests in `Core/Tests/BudgetCoreTests/CoupleLedgerTests.swift` and `Apple/Tests/CoupleStoreTests.swift`.
