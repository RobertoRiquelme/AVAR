# AVAR2

A SwiftUI + RealityKit app for visionOS and iOS that loads 2D/3D layout data and visualizes it in an immersive spatial scene. Nodes (boxes, spheres, cylinders, cones) and their connections (edges) are rendered in 3D. Features include interactive node dragging, HTTP server for remote diagram loading, collaborative sessions with SharePlay, and multi-platform support.

## Requirements
- macOS 15+ (Sequoia) for development
- Xcode 16+
- visionOS 2.0+ for full immersive experience
- iOS 18+ for companion AR view
- Target device or simulator with RealityKit support

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

## Features

### Input Sources
The app supports three input modes via a segmented picker:

1. **From File**: Select from pre-loaded example diagrams in the app bundle
2. **From JSON**: Paste JSON data directly into the text editor with validation
3. **HTTP Server**: Start a local HTTP server to receive diagrams from external sources

### HTTP Server
- Start/stop a local HTTP server from the app
- Accepts POST requests to `/avar` endpoint with JSON diagram data
- Automatically draws received diagrams in the immersive space
- Supports diagram updates via ID tracking
- View server logs and received JSON in real-time
- Example usage:
  ```bash
  curl -X POST http://<device-ip>:8081/avar \
    -H "Content-Type: application/json" \
    -d @diagram.json
  ```

### Collaborative Sessions
- **SharePlay Integration**: Share diagrams with other users in real-time
- **Shared Spatial Anchors**: Diagrams appear in the same physical location for all participants
- **Multi-device Support**: visionOS devices can share, iOS devices receive-only
- **Session Management**: Visual indicators for active sessions and shared anchors

### Immersion Controls
- **Keyboard shortcuts** (in immersive space):
  - Spacebar: Toggle debug info
  - Up/Down arrows: Adjust immersion level
  - R: Reset immersion to 0%
  - F: Full immersion (100%)
- **Button controls** from launcher window to set specific immersion levels (0%, 25%, 50%, 75%, 100%)
- **Digital Crown simulation**: Vertical drag gesture in immersive space

## Immersive View

Once in the immersive space:

- **Multiple Diagrams**: Load and display multiple diagrams simultaneously
- **Spatial Positioning**: Diagrams are automatically positioned using intelligent placement algorithms
- **Smart Snapping**: Diagrams snap to detected horizontal surfaces for stable placement
- **Plane Visualization**: Toggle visualization of detected planes (automatically disabled in full immersion)
- Nodes are placed at eye-level, 1 m in front of you, scaled according to data units
- Supported shapes: **Box**, **Sphere**, **Cylinder**, **Cone** (fallback to small box)
- Connections (edges) are drawn as thin gray lines between nodes
- **Drag** any node to reposition it; lines update in real time
- **Window Controls**: Grab the handle at the bottom center of each diagram to move its window in space, and tap the close button next to the handle to close the diagram
- **Surface Detection**: Real-time plane detection for AR placement (visionOS only)

## Data Format

Diagrams are defined in JSON format. The app supports two formats:

### Array Format (Direct)
```json
[
  {
    "model": "ClassName",
    "position": [x, y, z],
    "extent": [width, height, depth],
    "shape": {
      "shapeDescription": "RWBox|RWCylinder|RWSphere|RWCone",
      "extent": [width, height, depth],
      "color": [r, g, b, a]
    },
    "from_id": "optional_edge_source",
    "to_id": "optional_edge_target"
  }
]
```

### Object Format (With Metadata)
```json
{
  "elements": [...],
  "id": 123,
  "is2D": false
}
```

### Diagram ID Tracking
- Diagrams with an `id` field support updates: sending a new diagram with the same ID will replace the existing one
- Diagrams without an ID are always added as new instances

To add a new example:
1. Place your JSON file (with extension `.json` or `.txt`) into `AVAR2/Resources/`
2. Rebuild the app; the file will appear in the launcher menu

## Project Structure

### Core Files
- **PlatformApp.swift**: Main app entry point with platform-specific UI (visionOS/iOS)
  - `VisionOSMainView`: Launcher window for visionOS
  - `VisionOSImmersiveView`: Immersive space wrapper
- **AVAR2App.swift**: Shared UI components and views
  - `HTTPServerTabView`, `ServerStatusView`, `ServerLogsView`
  - `ImmersiveSpaceWrapper`: Background and content management
  - `StaticSurfaceView`: Plane detection visualization
  - `FPSMonitor`: Performance monitoring
- **ContentView.swift**: RealityView container for individual diagrams
- **ElementViewModel.swift**: Entity creation, positioning, drag interactions, and scene management
- **AppModel.swift**: App-wide state management (diagram positioning, surface detection, settings)

### Data Layer
- **ElementDTO.swift**: Data models and JSON decoding
- **ElementService.swift**: File loading from bundle and shared storage
- **DiagramDataLoader.swift**: Centralized loading with error handling
- **DiagramStorage.swift**: Shared file storage for HTTP-received diagrams

### Networking & Collaboration
- **HTTPServer.swift**: Local HTTP server for receiving diagrams
- **CollaborativeSessionManager.swift**: SharePlay integration and spatial anchor sharing
- **CollaborativeSessionView.swift**: Session management UI

### Surface Detection (visionOS)
- **SurfaceDetector.swift**: ARKit plane detection and visualization
- **Extensions.swift**: Utility extensions for 3D transformations

### Platform-Specific
- **iOS_ContentView.swift**: iOS AR view (receive-only for collaboration)

### Resources
- **Resources/**: Example diagram files (JSON/TXT)
- **Packages/RealityKitContent/**: RealityKit assets (USDZ, materials)

## Customization

### Adding New Shapes
Extend `createEntity(for:)` in `ElementViewModel.swift`:
```swift
case "CustomShape":
    let mesh = MeshResource.generate...
    entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
```

### Adjusting Spatial Layout
- **Scale Factor**: Modify the division factor in `rebuildSceneIfNeeded()` (currently divides by 10)
- **Eye-Level Offset**: Adjust `initialPosition` in diagram positioning logic
- **Diagram Spacing**: Configure `spacingBetweenDiagrams` in AppModel

### HTTP Server Configuration
- **Port**: Default is 8081, configurable in `HTTPServer.swift`
- **Endpoint**: Default is `/avar`, can be customized
- **Storage**: Diagrams saved to shared app group container via `DiagramStorage`

### Collaboration Settings
- **Session Type**: Configure GroupActivity settings in `CollaborativeSessionManager`
- **Anchor Broadcasting**: Adjust broadcast frequency and confidence thresholds

## Debugging

### Verbose Logging
Set environment variable `AVAR_VERBOSE_LOGS` to enable detailed logging:
```bash
# In Xcode scheme
AVAR_VERBOSE_LOGS=1
```

### Performance Monitoring
- FPS display shown at bottom of launcher window
- Debug info toggle available in immersive space (Spacebar)

## Known Issues & Limitations
- HTTP server callback must be set in `.onAppear` for immediate availability
- Surface detection disabled automatically in full immersion mode
- iOS version is receive-only for collaborative sessions
- Plane visualization may impact performance with many detected surfaces

## License
This project is provided as-is. Modify and distribute freely.