# Budget & Receipts logo

The icon is **Rising receipt**: a receipt whose lines become a budget bar chart,
with an amber sparkle for the Vision and AI features. It uses the same frame as
Vault's macOS icon and takes its colours from Vault and Chitra, so the apps read
as one family.

| Token | Light | Dark | Use | Source |
|---|---|---|---|---|
| BrandCoral | `#EE4B4E` | `#FF6B6E` | brand, spending | Vault red `#EE3B36` |
| BrandPlum | `#5A1D63` | `#B45CC0` | deep brand, net | Chitra background `#6E1E5C` |
| BrandAmber | `#E8A321` | `#FFC454` | accent, AI, needs review | Chitra petals `#FFC454` |
| BrandBlush | `#FFC9C4` | `#5A2A3A` | soft fills | Vault ring `#FFC9C4` |
| BrandCream | `#FFF4E0` | `#2E1838` | paper, surfaces | Chitra glint `#FFECBE` |
| BrandInk | `#24112E` | `#FFF4E0` | text on brand | Chitra centre `#180C28` |
| AccentColor | `#E23E44` | `#FF6B6E` | system tint | |

The icon background is a diagonal gradient from coral (top left) to plum (bottom right).

## Files

- `make_concepts.py` draws the three concepts that were offered (A was chosen).
- `make_icons.py` writes `app-icon-ios.svg` (full bleed; iOS rounds the corners),
  `app-icon-macos.svg` (framed, like Vault), `logo-1024.png`, and the AppIcon and
  colour sets in `Apple/Shared/Assets.xcassets`.
- `render.swift` turns an SVG into a PNG with AppKit, so no extra tools are needed.

To change a colour or the drawing, edit the Python and run:

    python3 Design/logo/make_icons.py
