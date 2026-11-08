# Savings goals, reimbursements and trips

All three live in **Plan**, and a payment's own editor gets **Paid back** and **Travel** sections.
Money is `Decimal` throughout and formatted with `AppSettings.currency`.

## Savings goals (`Core/SavingsGoals.swift`)
- `SavingsGoal`: name, target, optional deadline, SF Symbol, owner (`nil`/`.shared` = both of you,
  `.mine` / `.partner` = one person's), `isPrivate`, and a list of contributions (date, amount, who).
- `monthlyNeeded` counts the deadline's own month and rounds up to the penny; `projectedDate` uses the
  last three months' pace. Negative contributions are money taken back out.
- Stored in `goals.json`, synced as collection `goals` (private when marked). A partner's device flips
  the owner and each contribution's `by`.
- Home shows up to three unfinished goals (Settings › Goals and travel › Show savings goals on Home).

## Reimbursements (`Core/Reimbursements.swift`)
- `BankTransaction.reimbursement` (who, amount, received date, repayment credit id) and, on the credit,
  `BankTransaction.repays`.
- `BudgetCalculator.allocations` takes the reimbursed part off a payment (split payments shrink in
  proportion, to the penny, the last split taking the rounding) and a linked repayment is neither
  income nor a refund. The Me/Partner views scale the reimbursement with the share.
- Plan › Owed back to you lists what's still outstanding. "Mark Paid Back" offers credits of exactly
  the amount from the day before to 120 days after.

## Trips (`Core/Trips.swift`)
- `Trip`: name, first and last day, currency there, optional budget, owner, private, and payments taken off it.
- A trip's payments: ones put on it by hand (`BankTransaction.tripID`, e.g. flights booked earlier) plus
  spending in its dates that was in another currency or is a card's foreign fee. "Add N more payments
  from these dates" puts the rest of that spending on it.
- `ForeignAmount` (amount, currency, fee included) is read from statement text such as
  "EUR 42.50 @ 1.1622" when payments are imported (Settings › Read other currencies from statements) or
  entered by hand. The rate leaves the fee out.
- The summary gives the total after reimbursements, card fees (their own lines plus fees on payments),
  what was paid in the trip's currency, the average rate, per-day spend and categories.
