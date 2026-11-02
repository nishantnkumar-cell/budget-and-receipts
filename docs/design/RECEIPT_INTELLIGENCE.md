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

Income and payments that are already split or already have a receipt are never offered.

### Receipts that arrive before the statement

A receipt is often scanned before its payment reaches a statement. After scanning, "Not on my statement yet. Save for later" keeps it as a waiting receipt. Nothing is processed: no splits are made and nothing is approved. The Inbox shows a "receipts waiting for a payment" banner.

When a statement is imported, each waiting receipt is matched automatically only when the match is certain:

- the payment has exactly the receipt total;
- it is dated between 2 days before and 7 days after the receipt date (`MatchWindow`). Card payments often post a few days later, longer over weekends. A receipt without a printed date uses the day it was scanned;
- it is the only such payment, or the only one from the same shop;
- no other waiting receipt wants the same payment.

A matched receipt becomes a draft on that payment and still waits in the Inbox for the person to check and approve. Anything less certain, such as a tip or two equal payments, stays waiting, with the best payments suggested so the person can pick one or delete the receipt.

## Smart reading with Apple Intelligence (part 2)

When the rules can't make a receipt's items add up to its total, the app asks Apple's on-device model (Foundation Models) to read the OCR text. `ReceiptAIService` lives in the app and `ReceiptAIMerge` is the checking logic in Core. The model never sees the image, only the text, and nothing leaves the device.

The model's answer is checked before it is used:

- Every item price must be printed somewhere on the receipt. If even one isn't, none of the model's items are used.
- Its items replace the rules' items only when they add up to a printed total, or fit the total better.
- Unknown categories become Uncategorised.
- A good rules-based reading is never sent to the model.

Settings › Receipts › Smart receipt reading turns it off. It is on by default, and the footer says when the device can't run Apple Intelligence. The rules reader also now pairs a price printed on its own line with the name above it.

## Sharing receipts and statements into the app

"Budget & Receipts" appears in the share sheet on iPhone and Mac (a Share Extension). It also appears under "Open in…" on iPhone and Open With on the Mac.

- **Receipts**: PDF e-receipts (from Mail, Files or a shop's app) and images. A PDF's own text is read exactly. A scanned PDF or a photo is read with Vision. Smart reading helps when the items don't add up. The receipt goes to "Waiting for payment" and is matched when its payment arrives.
- **Statements**: CSV, OFX, QFX and QIF files from a bank app are imported straight away. Lines already imported are skipped, and waiting receipts are matched. A CSV whose columns can't be guessed is left for Import Statement. PDF bank statements are not supported.

The extension only copies files into a shared App Group folder (`SharedReceiptDrop`). The app reads them when it next becomes active (`SharedReceiptReader`), and removes the copies once read. App Groups: `group.com.nishantkumar.budgetreceipts` on iPhone, and `VCWH3ZCZ5J.com.nishantkumar.budgetreceipts` on the Mac, where a team-prefixed group needs no provisioning profile.
