# Edge-case tests

The approval policy compares positive split allocation magnitudes with the absolute bank transaction amount. A negative bank amount denotes a purchase/debit; a positive bank amount can denote a refund/credit. Negative split rows remain invalid because refunds are represented by the transaction direction, not by mixing positive and negative allocations within one split.

Tests cover exact penny allocation, half-penny tolerance, rejection beyond tolerance, Decimal 0.10 + 0.20 behaviour, full and partial refunds, refund over-allocation, negative purchases, large negative purchases, zero-value transactions and negative split rows.
