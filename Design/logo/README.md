# Budget & Receipts logo

The icon is **Rising receipt**: a receipt whose lines become a budget bar chart,
with an amber sparkle for the Vision and AI features. Its colours are Chitra's
icon colours (from `~/Chitra/tools/make_icon.py`), so the two apps read as one
family; the frame matches Vault's macOS icon.

| Token | Light | Dark | Use | Chitra source |
|---|---|---|---|---|
| BrandIndigo | `#261852` | `#8C7BD6` | net, deep brand | background top |
| BrandPlum | `#6E1E5C` | `#C05AA8` | deep brand | background bottom |
| BrandPink | `#E93278` | `#EC6096` | brand, spending | front petal edge |
| BrandAmber | `#D9961C` | `#FFC454` | accent, AI, needs review | front petal centre `#FFC454` |
| BrandCream | `#FFECBE` | `#2A1840` | paper, surfaces | lens glint |
| BrandInk | `#180C28` | `#FFECBE` | text on brand | lens centre |
| AccentColor | `#D9286C` | `#EC6096` | system tint | |

The icon background is a vertical gradient from indigo (top) to plum (bottom),
and the bars run pink to amber like Chitra's petals.

## Files

- `make_concepts.py` draws the three concepts that were offered (A was chosen).
- `make_icons.py` writes `app-icon-ios.svg` (full bleed; iOS rounds the corners),
  `app-icon-macos.svg` (framed, like Vault), `logo-1024.png`, and the AppIcon and
  colour sets in `Apple/Shared/Assets.xcassets`.
- `render.swift` turns an SVG into a PNG with AppKit, so no extra tools are needed.

To change a colour or the drawing, edit the Python and run:

    python3 Design/logo/make_icons.py
