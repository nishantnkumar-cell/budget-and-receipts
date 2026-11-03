# How data is shown, and where

Reviewed on 3 November 2026, after Nishant saw figures for November when he had no November payments yet (his statements ran to October).

## The rule

A screen either shows **one month** (the month switcher's) or **all of it**. It says which, and a month with no payments is never shown as if it had them.

## Screen by screen

| Screen | Period | Change |
|---|---|---|
| Home › Left to spend, safe to spend, forecast | Selected month | An empty month shows "No payments for November" with **Show October** instead of budgets and averages. A month still in progress says "Payments up to 22 Oct". |
| Home › Spending by account | Selected month | Hidden for an empty month. |
| Home › Budgets | Selected month | Hidden for an empty month. Tentative budgets (3-month averages) are only shown alongside real spending. |
| Home › Who owes whom, Coming up, Net worth | All time / the days ahead | Unchanged: they don't depend on the month. |
| Budgets | Selected month | Empty-month notice at the top. Each category's sheet shows where the money went by sub-category. |
| Month in review | Selected month | Empty-month notice. |
| Activity (iPhone and Mac) | All months, newest first | Unchanged: it's the full list, grouped by day. Search includes tags. |
| Mac Overview › key numbers | Selected month | Replaced by the empty-month notice. |
| Mac Overview › activity table | **Now the selected month** (it showed every month under the month's title) | Titled "October activity"; "See All" opens Activity. |
| Mac sidebar › accounts | Selected month | The tooltip now says so. |
| Mac Overview › Next 7 days, Needs you | The days ahead / now | Unchanged. |

## Opening the app

When the current month has no payments but older months do, the app opens on the latest month with payments, rather than an empty current month.

## Categories

- **Order of decisions:** your own rules, then what you chose for that shop before, then the starter rules, then built-in keywords, then Apple Intelligence or Apple Maps.
- **Rules:** `Core/Sources/BudgetCore/Rules.swift`. There are 50 starter rules covering UK bank wording (card repayments, pay, interest, transfers) and well-known shops, each with a sub-category. Your own rules are added in Settings › Category Rules or from any payment with **Make a Rule**, and they sync between devices. Starter rules are turned off rather than deleted, and new ones arrive with updates.
- **Sub-categories:** `FinanceCategories.subcategories`. Budgets stay per category, and sub-categories show where the money went inside one.
- **Applying rules:** rules run on import and each time the app opens. They fill in only uncategorised payments and missing sub-categories, so a category you set yourself is never changed unless you save a rule and choose **Recategorise these payments now**.
