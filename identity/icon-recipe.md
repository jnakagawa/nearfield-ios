# App icon — source of truth

The shipped icon (build 37+) is **Jonah's provided artwork**:
`identity/nearfield-icon-source.png` (1254² master), a dense uniform-weight
contour field with the "nearfield" wordmark woven in.

To install it as the app icon (already done for build 37):
- flood-fill the black corner triangles to white (the master has pre-baked
  rounded corners; iOS applies its OWN mask, so ship a full-bleed square)
- center-crop square, resize to 1024² LANCZOS, RGB (no alpha)
- write to `NearfieldEnsemble/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png`
- NO rounded corners in the asset — iOS rounds it

Do NOT regenerate the icon from logotype.html anymore — that produced the
earlier renders (builds 2–36). This file is the final identity; replace only
if Jonah supplies a new master.
