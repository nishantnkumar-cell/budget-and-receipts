# Synthetic bank statements

Made-up statements used by the tests on every platform (the BudgetCore package and the Apple apps). They contain no real data.
Each file describes the same five lines for October 2026, so every importer must produce the same result:

| Date | Description | Amount |
| --- | --- | --- |
| 2026-10-01 | SALARY ACME LTD | 2500.00 |
| 2026-10-03 | TESCO STORES 2041 | -45.67 |
| 2026-10-03 | COSTA COFFEE | -3.20 |
| 2026-10-03 | COSTA COFFEE | -3.20 |
| 2026-10-15 | AMAZON REFUND, "BOOKS" | 12.99 |

The two coffees are deliberate: identical lines on one day are both real and must both import.
