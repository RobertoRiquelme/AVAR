# AVAR2 Printable Marker (15 cm)

Files
- `AVAR2_Marker_A.svg` — US Letter page, centered 150 mm square marker with a scale bar.
- `AVAR2_Marker_B.svg` — Alternative design (nested squares + dense features), also 150 mm.

Print Instructions
- Print from macOS Preview at 100% scale (no “fit to page”).
- Verify with a ruler: the inner square’s width is exactly 150 mm (15.0 cm).

Add to Xcode (both targets)
1. In your asset catalog, create (or use) a group named `AR Resources`.
2. Drag the printable image exported as PDF/PNG (or the SVG directly if supported) into `AR Resources`.
3. Select the asset:
   - Name: `marker` (or the exact name you want to use in-app).
   - Physical Width: `0.15 m`.
4. Ensure the same asset name and physical width are set for both the visionOS and iOS targets.

Using in the App
- VisionOS: the app automatically tracks the marker and broadcasts its pose.
- iOS: choose the marker ID in the picker; once both devices see the same marker, the diagrams co‑locate.

Notes
- Matte paper, good lighting, rigid backing improve tracking.
- You can duplicate the SVG and change the inner text to create multiple unique markers.
 - Set the asset name (e.g., `marker`, `markerB`) and pick the same name in the iOS picker.
