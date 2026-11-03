# Command centre: the design versus the app

Design G ("Command centre") on the [Mac directions canvas](https://claude.ai/artifact/62k5gxrxHnrVRxFMbPW2C7), checked component by component on 3 November 2026.

| Area | Component in the design | In the app |
|---|---|---|
| Sidebar | App name and ⌘K hint | **Added.** ⌘K opens a palette: go to any place, or find a payment by shop, category, tag or amount. |
| | Overview, Activity (with count), Receipts to check (badge), Budgets, Bills and subscriptions, Net worth | Built. **Added** the Activity count. The Inbox is now **To Check**: its badge counted uncategorised payments as "receipts". |
| | People: each person with what they spent | **Added** each person's spend for the month, with their share of shared costs. Before, People only appeared once a partner was set up. Now it always shows, with **Add Your Partner…** until there is one. |
| | Accounts with amounts | Built (spent this month in each account; the tooltip says so). The design showed balances, which the app only knows for accounts under Net worth. |
| | Sync status at the foot | Built. |
| Toolbar | Month back and forward | Built. |
| | **Me / Partner / Together switch** | Built, but it only shows once a partner's name is set (Settings › Couple). It hadn't appeared because the wipe for the clean test cleared that setting. It now uses **your name** ("Your name" in Settings › Couple), like the design ("Nishant / Priya / Together"). |
| | Search, Add receipt | Built. |
| Key numbers | Left to spend, Safe today, Partner owes you, Bills | Built, plus Net worth when you have accounts there. **Added** the small trend lines back. |
| Spending pace | This month vs last month vs budget, "ahead/behind pace" | Built. **Added** the "£1,359 by the 10th" label on today's point. |
| Needs you | Receipts to check, price rise, settle up, possible duplicate | Built: receipts, price rises, settle up, balances to update, shared files and going overdrawn. **Added** "N payments need a category" (separate from receipts) and **possible duplicates** (a payment added by hand that a statement also brought in). |
| Next 7 days | Bills by day | Built, with price-rise chips. |
| Activity table | Date, shop with initial, category dot, whose, account, amount | Built. **Added** the shop initials. It shows the month on screen, and sub-categories show as "Groceries › Supermarket". |

## Research top pick: splitting a payment by its receipt

Built since phase 1. In a payment's detail, **Scan or review receipt** reads the receipt, puts each item in a category and splits the payment once you approve. Budgets and reports count each part in its own category. **Added:** split payments now show their categories in Activity and the Mac table ("Split: Groceries, Health") instead of a single category.
