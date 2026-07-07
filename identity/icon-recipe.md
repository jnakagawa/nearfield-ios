# App icon render recipe

The icon is a headless render from `simulator/logotype.html`'s machinery —
NOT a screenshot (screenshots bake rounded corners + upscale blur; that
shipped once as 0.2.0(2) and looked soft/matted on the TestFlight page).

Recipe (run as JS in the loaded page; see git log for the full snippet):
- square 1536² SDF texture of lowercase "nearfield" (Arial Rounded 800,
  size 300, tracking 0.05) via the page's chamfer(); 16-bit SDF packed in
  G+B channels, range ±500 px (8-bit at that range shows contour jaggies)
- fresh 2048² WebGL canvas with the page's FS, topo branch replaced:
  word-echo contours near the word blending into vnoise terrain far from it
  (near = smoothstep(0, 5·spacing, sdf); wobble amp mix(0.35, 3.2, near)·spacing)
  plus a solid zero-contour stroke around the glyphs
- ink 0 (dark-on-white), density 0.55, weight 3.4, t 0
- export via canvas.toDataURL (true pixels), downsample 2048 -> 1024 LANCZOS
- full-bleed square, NO rounded corners (iOS applies its own mask)
