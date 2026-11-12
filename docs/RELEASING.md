# Releasing to TestFlight and the App Store

The iPhone and Mac apps share one bundle ID (`com.nishantkumar.budgetreceipts`), so they are one App Store Connect app with **universal purchase**: one purchase unlocks both.

## Already done in the code

| Requirement | Where |
| --- | --- |
| Privacy manifest (no tracking, no data collected, reasons for UserDefaults and file dates) | `Apple/Shared/PrivacyInfo.xcprivacy`, `Apple/ShareExtension/PrivacyInfo.xcprivacy` |
| Export compliance: only Apple's own encryption, so no question on each upload | `ITSAppUsesNonExemptEncryption: false` in `Apple/project.yml` |
| Version 1.0.0, and a new build number on every upload | `MARKETING_VERSION` in `Apple/project.yml`; `Scripts/testflight.command` uses the date and time |
| Welcome screen on a new install | `Apple/Shared/WelcomeView.swift` |
| Privacy policy | `docs/PRIVACY.md` |
| Open source licence | `LICENSE` (MIT) |

## One-time setup

1. **Make the repository public** (GitHub › Settings › General › Danger Zone › Change visibility). The privacy policy link below only works once it is public. The history was checked on 2026-11-08 for keys and passwords. On 2026-11-12 real names and bank details copied from statements were found in tests and comments and replaced with made-up ones. Test data must never come from a real statement: use names like "MR A PERSON", sort code 00-00-00 and account numbers like 12345678.
2. **iCloud production schema.** TestFlight and App Store builds use iCloud's *Production* environment, which starts empty and has no record types. In the [CloudKit Console](https://icloud.developer.apple.com) open `iCloud.com.nishantkumar.budgetreceipts` › Schema › **Deploy Schema Changes…** and deploy to Production. Do this again whenever a new record type or field is added. Data synced by development builds stays in the Development environment and does not appear in TestFlight builds; the data on each device is kept.
3. **Create the app in App Store Connect** › Apps › + › New App: platforms iOS and macOS, name *Duo Budget*, bundle ID `com.nishantkumar.budgetreceipts`, SKU e.g. `duobudget`.
4. **App Privacy** (App Store Connect › the app › App Privacy): answer **"No, we do not collect data from this app"**. Privacy policy URL: `https://github.com/nishantnkumar-cell/budget-and-receipts/blob/main/docs/PRIVACY.md`.
5. **Age rating:** answer No to everything (4+). **Category:** Finance.

## Upload a build

On the Mac, with Xcode signed in to the developer account:

```bash
Scripts/testflight.command          # iPhone and Mac
Scripts/testflight.command ios      # only one of them
```

After Apple has processed the build (10 to 30 minutes) it shows in App Store Connect › TestFlight.

- **Internal testers** (people in your App Store Connect team, up to 100) can install straight away.
- **External testers** (anyone, by email or a public link) need a short Beta App Review of the first build. It asks for a description, a contact email and what to test.

TestFlight is free for testers whatever the App Store price is.

## Price: US$1.99 and £1.49

Selling a paid app needs, once, in App Store Connect › Business: the **Paid Apps Agreement**, tax forms and a bank account. Also apply for the **App Store Small Business Program**, which lowers Apple's commission from 30% to 15% for developers earning under US$1 million a year.

Then App Store Connect › the app › Pricing and Availability › Add Pricing:

1. Base country **United States**, price **US$1.99**. Apple fills in the other countries from this.
2. Under the list of countries, change **United Kingdom** to **£1.49** by hand. UK prices include VAT, which Apple pays out of the price.

## Open source and a paid app

The MIT licence lets anyone read, build and reuse the code. The App Store build is the convenient, signed and updated version that people pay for. The name *Duo Budget* and the app icon are not covered by the licence (see the README), so copies on the App Store have to use their own name and icon.
