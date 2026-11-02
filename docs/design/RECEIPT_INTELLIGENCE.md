# Receipt intelligence (Phase 3, part 1)

Everything here runs on the device. Nothing is sent anywhere, and every suggestion stays editable: a scanned receipt is still a draft until you approve it (see MANUAL_APPROVAL.md).

## Automatic categories (`Categoriser`)

- Imported statement lines and scanned receipt items get a category suggestion. Categories you set by hand are never changed.
- It learns first. If you put "TESCO STORES" in Family before, new Tesco payments go to Family. Merchants are compared on a cleaned key: card wording, store numbers and towns are dropped ("CARD PAYMENT TO TESCO STORES 3297 LONDON" becomes "TESCO STORES").
- Receipt items learn from the splits you approved before ("Meal deal" goes to Eating out).
- Otherwise it uses a built-in list of well-known UK shops and common grocery and chemist words. Keywords only match whole words, so "BP" does not match "ABP".
- An item it doesn't recognise takes the shop's category. A credit only becomes Income (salary, HMRC and similar). Shop refunds are left for you.

## Receipt reading (`ReceiptParser`)

- Reads the shop name, skipping greetings, phone numbers and VAT numbers.
- Reads the date in UK day-first form (12/10/2026, 12-10-26, 12 Oct 2026) and rejects impossible dates.
- Reads the subtotal, VAT and total.
- Discount lines ("Clubcard Price -0.30", "0.50-") come off the item above them, never below zero.
- VAT codes after amounts ("1.20 A") and decimal commas ("12,50") are handled.
- Payment lines (VISA, CASH, CHANGE DUE) are not items. A "BIRTHDAY CARD" still is.

## Matching a receipt to a payment (`ReceiptMatcher`)

Card payments are ranked by:

- the total (exact match, or close, such as a tip added at the till);
- the date (same day is best, since a payment can post a day or two later);
- the shop name.

Income and payments that are already split are never offered.

## Smart reading with Apple Intelligence (part 2)

When the rules can't make a receipt's items add up to its total, the app asks Apple's on-device model (Foundation Models) to read the OCR text. `ReceiptAIService` lives in the app and `ReceiptAIMerge` is the checking logic in Core. The model never sees the image, only the text, and nothing leaves the device.

The model's answer is checked before it is used:

- Every item price must be printed somewhere on the receipt. If even one isn't, none of the model's items are used.
- Its items replace the rules' items only when they add up to a printed total, or fit the total better.
- Unknown categories become Uncategorised.
- A good rules-based reading is never sent to the model.

Settings › Receipts › Smart receipt reading turns it off. It is on by default, and the footer says when the device can't run Apple Intelligence. The rules reader also now pairs a price printed on its own line with the name above it.
