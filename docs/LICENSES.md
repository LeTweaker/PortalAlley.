# Asset licenses and attribution

All runtime assets are generated from source in this repository by `Tools/assetgen/`.
Since v1.3 the build also uses CC0 photographed surfaces and scanned props from Poly Haven
(listed below); everything else is original work. No fonts or sound samples ship in the app.

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

# Photographed surfaces and scanned props (v1.3)

Credit: **Poly Haven (https://polyhaven.com), CC0** - shown on the app's start card.
License: https://polyhaven.com/license (CC0 1.0: no attribution required; we credit anyway).

| Asset | Type | Authors | Source |
|---|---|---|---|
| Exterior Aircon Unit | model | Monsta3D | https://polyhaven.com/a/exterior_aircon_unit |
| Metal Trash Can | model | GurJas Studios | https://polyhaven.com/a/metal_trash_can |
| Modular Airduct Circular 01 | model | Riley Queen | https://polyhaven.com/a/modular_airduct_circular_01 |
| Mounted Fluorescent Lights | model | Ulan Cabanilla | https://polyhaven.com/a/mounted_fluorescent_lights |
| Propane Tank | model | Slinc | https://polyhaven.com/a/propane_tank |
| Rollershutter Window 03 | model | MP | https://polyhaven.com/a/rollershutter_window_03 |
| Security Camera 01 | model | Alexander Otterbeck, Yann Kervran | https://polyhaven.com/a/security_camera_01 |
| Security Light | model | Maximilian Schuster | https://polyhaven.com/a/security_light |
| Utility Box 01 | model | James Ray Cock | https://polyhaven.com/a/utility_box_01 |
| Utility Box 02 | model | James Ray Cock | https://polyhaven.com/a/utility_box_02 |
| Asphalt 02 | texture | Rob Tuytel | https://polyhaven.com/a/asphalt_02 |
| Black Painted Planks | texture | Dimitrios Savva | https://polyhaven.com/a/black_painted_planks |
| Concrete Layers | texture | Amal Kumar | https://polyhaven.com/a/concrete_layers |
| Concrete Tile Facade | texture | Charlotte Baglioni | https://polyhaven.com/a/concrete_tile_facade |
| Concrete Wall 008 | texture | Charlotte Baglioni, Dario Barresi | https://polyhaven.com/a/concrete_wall_008 |
| Corrugated Iron | texture | Dimitrios Savva, Jenelle van Heerden | https://polyhaven.com/a/corrugated_iron |
| Garage Floor | texture | Jenelle van Heerden | https://polyhaven.com/a/garage_floor |
| Mixed Brick Wall | texture | Dimitrios Savva | https://polyhaven.com/a/mixed_brick_wall |
| Painted Concrete 02 | texture | Rob Tuytel | https://polyhaven.com/a/painted_concrete_02 |
| Red Plaster Weathered | texture | Amal Kumar | https://polyhaven.com/a/red_plaster_weathered |
| Rust Coarse 01 | texture | Dimitrios Savva, Rico Cilliers | https://polyhaven.com/a/rust_coarse_01 |

How they are used
- Downloaded once by `Tools/fetch_cc0_assets.py` (CI workflow `fetch-cc0-assets.yml`), MD5-verified
  against Poly Haven's file metadata, committed under `Vendor/polyhaven/` with
  `provenance.json` (URL, MD5, SHA-256, size, authors for every file).
- Converted offline by `Tools/assetgen/photo.py` (surfaces: resized, luminance-normalised, ARM
  repacked) and `Tools/assetgen/props.py` (glTF -> mesh pack, textures resized to 512 px).
  The app bundle contains only the converted results; the app never contacts Poly Haven.
- Nothing was purchased; no paid or attribution-restricted asset is used.

# Photographic destinations (v1.4)

Both are shown with their credit line in the app (viewing picker and start card).

| Asset | Type | Author | Licence | Source | Shipped as |
|---|---|---|---|---|---|
| Woolwich Alley | photogrammetry capture (626 photos, Sony a7R III, RealityCapture, May 2022) of the alley between Woolwich High Street and Mortgramit Square, London | artfletch | CC BY 4.0 | https://sketchfab.com/3d-models/woolwich-alley-f95ea3f1c306450ea3996bb492f01394 (downloaded from the Objaverse 1.0 mirror, SHA-256 in provenance) | `meshes/capture_woolwich*.pmsh`, `textures/capture_woolwich_albedo.jpg` (cropped, re-oriented into portal space, LOD; texture unchanged except JPEG re-encode) |
| Heavy rain in early spring in Tokyo | video, 1280x720, 10.4 s | Fumikas Sagisavas | CC BY 4.0 | https://commons.wikimedia.org/wiki/File:Heavy_rain_in_early_spring_in_Tokyo.webm | `video/tokyo_heavy_rain.mp4` (H.264 transcode, content unaltered) |

Attribution text used in the app:
- "Woolwich Alley" by artfletch, CC BY 4.0
- "Heavy rain in early spring in Tokyo" by Fumikas Sagisavas, CC BY 4.0 (Wikimedia Commons)

Provenance files: `Vendor/captures/woolwich_alley/provenance.json`, `Vendor/footage/tokyo_heavy_rain/provenance.json`.
Changes made: geometry cropped/transformed/decimated; video re-encoded. Nothing was purchased.
