# AVAR2

A SwiftUI + RealityKit sample app that loads 2D/3D layout data and visualizes it in an immersive spatial scene. Nodes (boxes, spheres, cylinders, cones) and their connections (edges) are rendered in 3D, and you can interactively drag nodes to reposition them with real-time updated connections.

## Requirements
- macOS 14+ (Sonoma) / VisionOS 1.0+
- Xcode 15 or later
- Target device or simulator with RealityKit 2 support

## Getting Started

1. Clone or download the repository:
   ```bash
   git clone <repo-url>
   cd AVAR2
   ```
2. Open the Xcode project:
   ```bash
   open AVAR2.xcodeproj
   ```
3. Build and run the app on a compatible device or simulator.

## Launcher Window

When the app launches, you will see a 2D launcher window:

- **Select Example**: Drop-down menu listing all example layout files (JSON or TXT) in `AVAR2/Resources`. Choose the layout you want to visualize.
- **Enter Immersive Space**: Opens the immersive RealityKit view showing your graph in 3D.
- **Add Diagram**: Adds the currently selected diagram into the immersive scene without closing existing content.
- **Exit Immersive Space**: Closes the immersive session and clears all loaded diagrams.

## Immersive View

Once in the immersive space:

- Nodes are placed at eye-level, 1 m in front of you, scaled according to data units.
- Supported shapes: **Box**, **Sphere**, **Cylinder**, **Cone** (fallback to small box).
- Connections (edges) are drawn as thin gray lines between nodes.
- **Drag** any node to reposition it; lines update in real time.

## Data Files

All example layouts are stored as JSON-like files in `AVAR2/Resources/` with extension `.json` or `.txt`. Each file defines an array of elements with properties:
- `id`, `type`, `position` (x, y, z), optional `shape` (`shapeDescription`, `extent`, `color`, `text`), and optional `from_id`/`to_id` for edges.

To add a new example:
1. Place your JSON file (with extension `.json` or `.txt`) into `AVAR2/Resources/`.
2. Rebuild the app; the file will appear in the launcher menu.

## Project Structure

- **AVAR2/**: Main Swift package
  - `AVAR2App.swift`: App entry, launcher and ImmersiveSpace scenes
  - `ContentView.swift`: Embeds RealityView and kicks off data loading
  - `ElementDTO.swift`, `ElementService.swift`: Data parsing
  - `ElementViewModel.swift`: Creates & positions entities, manages connections and drag interactions
  - `Extensions.swift`: Utility for 3D drag translations
  - `ToggleImmersiveSpaceButton.swift`: Button helper for immersive state
  - **Resources/**: Example data files
- **Packages/RealityKitContent/**: SwiftPM package with RealityKit assets (USDZ, materials)

## Customization
- **Shapes**: Extend `createEntity(for:)` in `ElementViewModel.swift` to support additional shape types.
- **Scaling & Position**: Adjust the division factor or eye-level offset in `loadElements(in:)`.
- **Styling**: Modify materials, labels, or grid style in the view model.

## License
This project is provided as-is. Modify and distribute freely.