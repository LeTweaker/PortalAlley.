# Asset licenses and attribution

All runtime assets are generated from source in this repository by `Tools/assetgen/` and are
original work. No third-party models, textures, photos, sound samples or fonts ship in the app.

| Asset | Origin | License |
|---|---|---|
| Doorway + alley geometry (`meshes/*.pmsh`) | procedurally authored (`frame.py`, `alley.py`) | same as this project |
| Material textures, sky, rain, steam, puddles | procedural (`texkit.py`) | same as this project |
| Shop interiors, vending fronts, posters | procedural (`interiors.py`, `signs.py`) | same as this project |
| Sign / lantern / noren lettering | rasterised at build time from **Noto Sans CJK JP / Noto Serif CJK JP** (Google/Adobe) | SIL Open Font License 1.1 - rendered images are not font software; no font file is bundled. Attribution appreciated: "Lettering set in Noto Sans/Serif CJK (SIL OFL 1.1)". |
| Audio (`rain_loop`, `city_loop`, `hum_loop`, `portal_open/close`) | synthesised (`audio.py`, numpy/scipy) | same as this project |
| App icon | crop of a preview render of this project | same as this project |

All businesses are fictional: ほたる横丁, 喫茶ミナト, BAR 夜霧, 古書ふくろう堂, コインランドリー 24H,
居酒屋しずく, 薬 ひかり, らーめん 灯, ヨルマート, and the stacked-sign tenants. No real brands or logos.

Build tooling (not shipped): Python 3, NumPy, SciPy, Pillow; XcodeGen; GitHub Actions.
Sideloading (your machine, not part of this project): Sideloadly, iTunes/iCloud for Windows.
