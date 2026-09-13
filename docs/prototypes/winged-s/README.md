# Winged S candidate

Source-faithful manual vector reconstruction of the user's selected “Original Refined” photo reference. The photo is not an editable vector, so curves are reconstructed rather than claimed byte-exact. Preserved upper swept two-feather charcoal band, lower slate S band, pointed inner terminals and overall proportions. Removed photographic shading, rounded outer icon tile and caption. No new logo concept.

Master: `winged-s-master.svg`. Candidate: `winged-s-app-icon-candidate.png`, 1024×1024 RGB PNG, no alpha. Full-bleed paper #F7F3EA, charcoal #20252B, slate #8DA4B5. iOS supplies the outer icon mask. Root visually approved the candidate; identical PNG copied into `AppIcon.appiconset/semreh_app_icon.png` and `SemrehAppIcon.imageset/semreh_app_icon.png` under `HermesMobile/Resources/Assets.xcassets`. Both production copies checked 1024×1024 with no alpha. Existing catalog filename entries remain valid and unchanged. Asset diff check passed. Native validation pending verifier.

Reproduce from this directory:

```sh
qlmanage -t -s 1024 -o . winged-s-master.svg
swift export-opaque.swift winged-s-master.svg.png winged-s-app-icon-candidate.png
sips -g pixelWidth -g pixelHeight -g hasAlpha winged-s-app-icon-candidate.png
```

Quick Look SVG rendering succeeded and was visually inspected. `sips` reports 1024×1024, hasAlpha: no for candidate. Initial AppKit RGB-context attempt failed before writing; current exporter uses CoreGraphics with noneSkipLast and ImageIO PNG export successfully. The combined signed Simulator build subsequently compiled the production asset catalogs successfully. The captured Springboard page did not contain Semreh, so installed-icon appearance is not claimed verified.
