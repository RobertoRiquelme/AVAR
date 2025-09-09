AR Resources (Reference Images)

Use this group to add AR Reference Images for image tracking on both visionOS and iOS.

Add a marker image
1) Drag your printed marker image (PNG or JPEG) into this group.
2) Select the new item in the asset inspector and set:
   - Name: marker (or a custom name)
   - Physical Width: 0.15 m (or the exact measured width of your print)
3) Make sure this asset catalog is included in both targets.

Notes
- Supported formats: PNG, JPEG (PDF/SVG are not supported for reference images).
- Use the same asset name and Physical Width on visionOS and iOS.
- You can add multiple images; the iOS app shows a picker of all available names.

