# Raw Turf — Third-Party Assets

This manifest documents every third-party asset integrated into the project.
All assets below are CC0 (public domain dedication). No modifications have
been made to the source files other than selective extraction, renaming for
clarity, and Godot import. Original archives in `downloads_assets/` are
preserved untouched.

## 1. Kenney — Car Kit (3.1)

- Creator: Kenney (www.kenney.nl)
- Source: https://kenney.nl/assets/car-kit
- Local archive: `downloads_assets/kenney_car-kit.zip` (268 entries, verified)
- License: Creative Commons Zero (CC0) — see
  `assets/licenses/kenney_car-kit_License.txt`
- Attribution: not required; crediting "Kenney / www.kenney.nl" appreciated.
- Redistribution: permitted for personal, educational, and commercial use
  (verified in local `License.txt`).
- Integrated file:
  - `assets/vehicles/kenney_van.glb` (from `Models/GLB format/van.glb`)
- Modifications: none (renamed on extraction only).
- Used for: courier-van decorative visual (Task 7A Stage 3).
- Required companion texture (GLB external URI `Textures/colormap.png`;
  import fails without it — Stage 2 finding):
  - `assets/vehicles/Textures/colormap.png`
    (from `Models/GLB format/Textures/colormap.png`)

## 2. Kenney — City Kit Commercial (2.1)

- Creator: Kenney (www.kenney.nl)
- Source: https://kenney.nl/assets/city-kit-commercial
- Local archive: `downloads_assets/kenney_city-kit-commercial_2.1.zip`
  (228 entries, verified)
- License: Creative Commons Zero (CC0) — see
  `assets/licenses/kenney_city-kit-commercial_License.txt`
- Attribution: not required; crediting "Kenney / www.kenney.nl" appreciated.
- Redistribution: permitted for personal, educational, and commercial use
  (verified in local `License.txt`).
- Integrated files (all from `Models/GLB format/`):
  - `assets/buildings/kenney_building-a.glb` (building-a.glb)
  - `assets/buildings/kenney_building-d.glb` (building-d.glb)
  - `assets/buildings/kenney_building-f.glb` (building-f.glb)
  - `assets/buildings/kenney_building-j.glb` (building-j.glb)
- Modifications: none (renamed on extraction only).
- Used for: Harbor Row building facade visuals (Task 7A Stage 4).
- Required companion textures (GLB external URIs; import fails without them):
  - `assets/buildings/Textures/colormap.png`
    (from `Models/GLB format/Textures/colormap.png`)
  - `assets/buildings/Textures/variation-a.png`
    (from `Models/Textures/variation-a.png`)
  - `assets/buildings/Textures/variation-b.png`
    (from `Models/Textures/variation-b.png`)
- Note: `kenney_building-d.glb` is imported as a spare but not instanced in
  any scene yet (three distinct facades used: a, f, j).

## 3. Kenney — City Kit Roads (2.2)

- Creator: Kenney (www.kenney.nl)
- Source: https://kenney.nl/assets/city-kit-roads
- Local archive: `downloads_assets/kenney_city-kit-roads.zip`
  (496 entries, verified)
- License: Creative Commons Zero (CC0) — see
  `assets/licenses/kenney_city-kit-roads_License.txt`
- Attribution: not required; crediting "Kenney / www.kenney.nl" appreciated.
- Redistribution: permitted for personal, educational, and commercial use
  (verified in local `License.txt`).
- Integrated files (all from `Models/GLB format/`, 6 prop types):
  - `assets/props/kenney_construction-cone.glb`
  - `assets/props/kenney_construction-barrier.glb`
  - `assets/props/kenney_dumpster.glb`
  - `assets/props/kenney_light-curved.glb`
  - `assets/props/kenney_road-sign-stop.glb`
  - `assets/props/kenney_traffic-light.glb`
- Modifications: none (renamed on extraction only).
- Used for: collision-free street props (Task 7A Stage 5).
- Required companion textures (GLB external URIs; import fails without them):
  - `assets/props/Textures/colormap.png`
    (from `Models/GLB format/Textures/colormap.png`)
  - `assets/props/Textures/variation-a.png`
    (from `Models/Textures/variation-a.png`)

## 4. Poly Haven — asphalt_02 1K PBR texture set

- Creator: Poly Haven contributors (www.polyhaven.com)
- Source: https://polyhaven.com/ (asset `asphalt_02`)
- Local files: `downloads_assets/textures/asphalt_02_1k/*.jpg` (3 maps)
- License: Creative Commons Zero (CC0) per https://polyhaven.com/license
  (verified 2026-10-14; all Poly Haven HDRIs, textures, and models are CC0,
  no attribution required, commercial use allowed).
- License-file note: the pre-downloaded texture folder contained NO local
  `License.txt`. This is recorded here as a Stage 0 discrepancy; the CC0
  grant above is from Poly Haven's published license page, not a bundled file.
- Attribution: not required.
- Redistribution: permitted (CC0 public-domain dedication).
- Integrated files (copied unmodified):
  - `assets/textures/asphalt_02_1k/asphalt_02_diff_1k.jpg`
  - `assets/textures/asphalt_02_1k/asphalt_02_nor_gl_1k.jpg`
  - `assets/textures/asphalt_02_1k/asphalt_02_rough_1k.jpg`
- Modifications: none.
- Used for: road/dock asphalt albedo + normal + roughness (Task 7A Stage 5).

## 5. Poly Haven — concrete_pavement 1K PBR texture set

- Creator: Poly Haven contributors (www.polyhaven.com)
- Source: https://polyhaven.com/ (asset `concrete_pavement`)
- Local files: `downloads_assets/textures/concrete_pavement_1k/*.jpg` (3 maps)
- License: Creative Commons Zero (CC0) per https://polyhaven.com/license
  (verified 2026-10-14; same site-wide CC0 grant as above).
- License-file note: same discrepancy — NO local `License.txt` was bundled
  with the pre-downloaded folder; CC0 verified via the published license page.
- Attribution: not required.
- Redistribution: permitted (CC0 public-domain dedication).
- Integrated files (copied unmodified):
  - `assets/textures/concrete_pavement_1k/concrete_pavement_diff_1k.jpg`
  - `assets/textures/concrete_pavement_1k/concrete_pavement_nor_gl_1k.jpg`
  - `assets/textures/concrete_pavement_1k/concrete_pavement_rough_1k.jpg`
- Modifications: none.
- Used for: sidewalk/curb/dock concrete albedo + normal + roughness
  (Task 7A Stage 5).

## Verification summary (Stage 0/1, 2026-10-14)

- 9 approved download files verified on disk: 3 ZIP archives
  (4,814,237 + 4,096,974 + 2,852,289 bytes) + 6 JPG maps
  (731,707 + 1,240,122 + 544,032 + 926,197 + 1,184,345 + 475,799 bytes)
  = 16,865,702 bytes (~16.08 MB). Matches the acquisition report.
- All 3 Kenney ZIPs pass integrity check with `License.txt` (CC0) present.
- GLB is the imported model format (Godot 4.7.2 best support; FBX/OBJ/PNG
  duplicates intentionally NOT extracted).
- No archives deleted; no existing files overwritten.
