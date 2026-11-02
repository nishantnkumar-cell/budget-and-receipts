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

# Colour tokens: name -> (light, dark). Dark values are lifted for contrast on dark backgrounds.
COLOURS = {
    "AccentColor": ("#D9286C", "#EC6096"),
    "BrandPink": (PALETTE["pink"], "#EC6096"),
    "BrandPlum": (PALETTE["plum"], "#C05AA8"),
    "BrandIndigo": (PALETTE["indigo"], "#8C7BD6"),
    "BrandAmber": ("#D9961C", PALETTE["amber"]),
    "BrandCream": (PALETTE["cream"], "#2A1840"),
    "BrandInk": (PALETTE["ink"], PALETTE["cream"]),
    # Surfaces for the redesigned screens: a warm page with white cards.
    "ScreenBackground": ("#F7F3EE", "#120A1E"),
    "CardBackground": ("#FFFFFF", "#22152F"),
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
