"""Builds the chosen logo into the Apple app: icon SVGs, AppIcon PNGs and colour sets.

Run from anywhere on a Mac: python3 Design/logo/make_icons.py
Needs only Python 3 and the Swift toolchain (render.swift draws SVGs with AppKit).
"""
import json
import subprocess
import tempfile
from pathlib import Path

from make_concepts import PALETTE, RISING_RECEIPT, frame, full_bleed

HERE = Path(__file__).parent
ASSETS = HERE.parent.parent / "Apple" / "Shared" / "Assets.xcassets"

MAC_SIZES = [16, 32, 128, 256, 512]

# Colour tokens: name -> (light, dark). "Graphite and violet" (chosen 2026-11-02): neutral greys
# with one violet accent; the token names are older than the scheme, so their roles are:
# BrandPink = the main violet accent, BrandPlum/BrandIndigo = deeper violets for icons and "mine",
# BrandPartner = the partner's colour, BrandTeal = shared, BrandAmber = warnings.
COLOURS = {
    "AccentColor": ("#5E5CE6", "#8B89FF"),
    "BrandPink": ("#5E5CE6", "#8B89FF"),
    "BrandPlum": ("#4F4DD6", "#A3A1FF"),
    "BrandIndigo": ("#3F3DBF", "#B4B2FF"),
    "BrandAmber": ("#C2700A", "#FBBF24"),
    "BrandCream": ("#F0F0F2", "#26262C"),
    "BrandInk": ("#18181B", "#EDEDF0"),
    "BrandPartner": ("#C0267A", "#F472B6"),
    "BrandTeal": ("#0E7C86", "#5EEAD4"),
    # Surfaces: a cool grey page with white cards, and the dark "left to spend" hero card.
    "ScreenBackground": ("#F7F7F8", "#0E0E11"),
    "CardBackground": ("#FFFFFF", "#17171B"),
    "HeroBackground": ("#1C1C22", "#1F1F26"),
    "HeroAccent": ("#A5A3FF", "#A5A3FF"),
}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def colour_component(hex_value):
    h = hex_value.lstrip("#")
    return {"color-space": "srgb", "components": {
        "red": f"0x{h[0:2]}", "green": f"0x{h[2:4]}", "blue": f"0x{h[4:6]}", "alpha": "1.000"}}


def colour_set(light, dark):
    return {"colors": [
        {"idiom": "universal", "color": colour_component(light)},
        {"idiom": "universal", "color": colour_component(dark),
         "appearances": [{"appearance": "luminosity", "value": "dark"}]},
    ], "info": {"author": "xcode", "version": 1}}


def main():
    (HERE / "app-icon-macos.svg").write_text(frame(RISING_RECEIPT))
    (HERE / "app-icon-ios.svg").write_text(full_bleed(RISING_RECEIPT))

    with tempfile.TemporaryDirectory() as tmp:
        renderer = Path(tmp) / "render"
        subprocess.run(["swiftc", "-O", str(HERE / "render.swift"), "-o", str(renderer)], check=True)

        def render(svg, png, size):
            subprocess.run([str(renderer), str(svg), str(png), str(size)], check=True)

        icon_dir = ASSETS / "AppIcon.appiconset"
        icon_dir.mkdir(parents=True, exist_ok=True)
        images = [{"filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
        render(HERE / "app-icon-ios.svg", icon_dir / "ios-1024.png", 1024)
        for size in MAC_SIZES:
            for scale in (1, 2):
                name = f"mac-{size}@{scale}x.png"
                render(HERE / "app-icon-macos.svg", icon_dir / name, size * scale)
                images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
        render(HERE / "app-icon-macos.svg", HERE / "logo-1024.png", 1024)
        write_json(icon_dir / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})

    write_json(ASSETS / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    for name, (light, dark) in COLOURS.items():
        write_json(ASSETS / f"{name}.colorset" / "Contents.json", colour_set(light, dark))


if __name__ == "__main__":
    main()
