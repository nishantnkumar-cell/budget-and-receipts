"""Generates the Budget & Receipts logo concepts as 1024px SVGs.

Shares the frame of Vault's macOS icon (824px squircle, 185 radius, soft drop
shadow) and draws its colours from Vault (coral red) and Chitra (plum, amber).
"""
from pathlib import Path

OUT = Path(__file__).parent

PALETTE = {
    "coral": "#EE4B4E",   # between Vault #EE3B36 and Chitra pink #E93278
    "plum": "#5A1D63",    # Chitra background bottom #6E1E5C, a little deeper
    "amber": "#FFC454",   # Chitra petal highlight
    "blush": "#FFC9C4",   # Vault ring
    "cream": "#FFF4E0",   # receipt paper, from Chitra glint #FFECBE
    "ink": "#24112E",     # Chitra centre #180C28, warmed
}


def defs(bg=("coral", "plum")):
    p = PALETTE
    return f'''<defs>
<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="100" y1="100" x2="924" y2="924"><stop offset="0" stop-color="{p[bg[0]]}"/><stop offset="1" stop-color="{p[bg[1]]}"/></linearGradient>
<linearGradient id="gold" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#F7834A"/><stop offset="1" stop-color="{p["amber"]}"/></linearGradient>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.28"/></filter>
<filter id="lift" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#2A0A2E" flood-opacity="0.35"/></filter>
</defs>'''


def frame(body, bg=("coral", "plum")):
    """Mac-style icon: rounded square with margin and shadow, as in Vault."""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
{defs(bg)}
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#shadow)"/>
{body}
</svg>
'''


def full_bleed(body, scale=1.12, bg=("coral", "plum")):
    """iPhone icon: square edge to edge (iOS rounds the corners itself)."""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
{defs(bg)}
<rect width="1024" height="1024" fill="url(#bg)"/>
<g transform="translate(512 512) scale({scale}) translate(-512 -512)">{body}</g>
</svg>
'''


def receipt(x, y, w, h, teeth=7, depth=30, r=30):
    """Receipt outline: rounded top, torn zigzag bottom."""
    step = w / teeth
    d = [f"M{x},{y + r}", f"Q{x},{y} {x + r},{y}", f"H{x + w - r}",
         f"Q{x + w},{y} {x + w},{y + r}", f"V{y + h}"]
    for i in range(teeth):
        right = x + w - i * step
        d.append(f"L{right - step / 2:.1f},{y + h - depth}")
        d.append(f"L{right - step:.1f},{y + h}")
    d.append("Z")
    return " ".join(d)


def sparkle(cx, cy, s, fill):
    k = s * 0.22
    return (f'<path fill="{fill}" d="M{cx},{cy - s} C{cx + k},{cy - k} {cx + k},{cy - k} {cx + s},{cy} '
            f'C{cx + k},{cy + k} {cx + k},{cy + k} {cx},{cy + s} C{cx - k},{cy + k} {cx - k},{cy + k} {cx - s},{cy} '
            f'C{cx - k},{cy - k} {cx - k},{cy - k} {cx},{cy - s}Z"/>')


P = PALETTE

# A: Rising receipt. The receipt's lines become a budget bar chart; a sparkle marks the AI.
RISING_RECEIPT = f'''<circle cx="512" cy="512" r="322" fill="#FFFFFF" fill-opacity="0.12"/>
<path filter="url(#lift)" fill="{P["cream"]}" d="{receipt(352, 236, 320, 540)}"/>
<rect x="400" y="300" width="150" height="26" rx="13" fill="{P["plum"]}" fill-opacity="0.35"/>
<rect x="400" y="350" width="100" height="26" rx="13" fill="{P["plum"]}" fill-opacity="0.2"/>
<rect x="404" y="560" width="56" height="130" rx="16" fill="url(#gold)"/>
<rect x="484" y="500" width="56" height="190" rx="16" fill="url(#gold)"/>
<rect x="564" y="420" width="56" height="270" rx="16" fill="{P["coral"]}"/>
{sparkle(690, 270, 66, P["amber"])}'''
a = frame(RISING_RECEIPT)

# B: Viewfinder. Vision scan brackets around a receipt with a total line.
br = 'fill="none" stroke="{c}" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"'.format(c=P["cream"])
b = frame(f'''<path {br} d="M250,370 V310 Q250,250 310,250 H370"/>
<path {br} d="M654,250 H714 Q774,250 774,310 V370"/>
<path {br} d="M774,654 V714 Q774,774 714,774 H654"/>
<path {br} d="M370,774 H310 Q250,774 250,714 V654"/>
<path filter="url(#lift)" fill="#FFFFFF" d="{receipt(382, 318, 260, 400, teeth=6, depth=26, r=24)}"/>
<rect x="422" y="372" width="180" height="22" rx="11" fill="{P["plum"]}" fill-opacity="0.3"/>
<rect x="422" y="420" width="130" height="22" rx="11" fill="{P["plum"]}" fill-opacity="0.3"/>
<rect x="422" y="468" width="160" height="22" rx="11" fill="{P["plum"]}" fill-opacity="0.3"/>
<rect x="408" y="532" width="208" height="8" rx="4" fill="{P["coral"]}"/>
<rect x="422" y="566" width="80" height="34" rx="17" fill="{P["coral"]}"/>
<rect x="522" y="566" width="80" height="34" rx="17" fill="url(#gold)"/>
{sparkle(712, 520, 46, P["amber"])}''', bg=("plum", "coral"))

# C: Two receipts. A pair of receipts (one person or a couple) with a coin-amber sparkle.
c = frame(f'''<circle cx="512" cy="512" r="322" fill="#FFFFFF" fill-opacity="0.12"/>
<g transform="rotate(-10 512 512)"><path filter="url(#lift)" fill="{P["blush"]}" d="{receipt(310, 270, 280, 480)}"/></g>
<g transform="rotate(7 512 512)"><path filter="url(#lift)" fill="{P["cream"]}" d="{receipt(430, 290, 290, 480)}"/>
<rect x="476" y="356" width="160" height="24" rx="12" fill="{P["plum"]}" fill-opacity="0.32"/>
<rect x="476" y="404" width="110" height="24" rx="12" fill="{P["plum"]}" fill-opacity="0.2"/>
<rect x="476" y="452" width="140" height="24" rx="12" fill="{P["plum"]}" fill-opacity="0.2"/>
<circle cx="575" cy="600" r="66" fill="url(#gold)"/>
<path d="M548,600 l20,20 l36,-42" fill="none" stroke="#FFFFFF" stroke-width="20" stroke-linecap="round" stroke-linejoin="round"/></g>
{sparkle(300, 300, 56, P["amber"])}''')

if __name__ == "__main__":
    for name, svg in {"concept-a-rising-receipt": a, "concept-b-viewfinder": b, "concept-c-two-receipts": c}.items():
        (OUT / f"{name}.svg").write_text(svg)
