# iOS Support for AVAR2

This document describes the multiplatform implementation of AVAR2 that supports both visionOS and iOS.

## Architecture Overview

### Multiplatform Structure

```
AVAR2/
├── Shared Components/
│   ├── SimplifiedCollaborativeSessionManager.swift  # Cross-platform collaboration
│   ├── HTTPServer.swift                            # Works on both platforms  
│   ├── DiagramSyncService.swift                    # Data synchronization
│   ├── ElementDTO.swift                            # Data models
│   └── CollaborativeSessionView.swift              # UI components
├── visionOS Specific/
│   ├── AVAR2App.swift                             # visionOS main app (wrapped in #if os(visionOS))
│   ├── ARKitSurfaceDetector.swift                 # visionOS ARKit implementation
│   └── ContentView.swift                          # visionOS 3D content
└── iOS Specific/
    ├── iOSApp.swift                               # iOS main app (@main for iOS)
    ├── iOSARKitManager.swift                      # iOS ARKit implementation  
    ├── iOSARViewContainer.swift                   # ARView container
    └── iOSContentView.swift                       # iOS 3D content adaptation
```

## Key Differences

### Surface Detection
- **visionOS**: Uses `ARKitSession` and `PlaneDetectionProvider`
- **iOS**: Uses `ARSession` with `ARWorldTrackingConfiguration`

### 3D Interaction
- **visionOS**: Direct hand/eye tracking in immersive space
- **iOS**: Touch gestures (tap, pan, pinch, rotate) on camera view

### UI Layout
- **visionOS**: Floating windows + immersive content
- **iOS**: Camera overlay with AR controls

## Features Implemented

### ✅ Completed iOS Features

1. **AR Surface Detection**: iOS ARKit with plane detection
2. **Touch Interaction**: Tap to place, drag to move, pinch to scale, rotate gestures
3. **Collaborative Sessions**: Full GroupActivities support for cross-platform collaboration
4. **HTTP Server**: Remote diagram loading
5. **3D Diagram Rendering**: Adapted from visionOS version with iOS-appropriate scaling
6. **Debug Mode**: UI testing without physical devices

### 🎯 iOS-Specific UI Flow

1. **AR Camera View**: Full-screen ARKit camera feed
2. **Status Overlay**: AR tracking status and surface count
3. **Control Overlays**: Floating action buttons for placing diagrams
4. **Settings Sheet**: Collapsible settings panel
5. **Toast Notifications**: Feedback for user actions

## Collaborative Features

### Cross-Platform Collaboration
Both iOS and visionOS versions can:
- Start/join collaborative sessions via GroupActivities
- Share diagrams in real-time
- Synchronize 3D positioning
- Exchange immersion level data (iOS interprets as opacity)

### Debug Testing
```swift
#if DEBUG
collaborativeManager.enableDebugMode() // Simulates collaborative states
#endif
```

## Touch Interactions (iOS)

### Gesture System
- **Tap**: Select/deselect diagrams, place new diagrams
- **Pan**: Move selected diagrams on detected surfaces  
- **Pinch**: Scale selected diagrams
- **Rotation**: Rotate selected diagrams around Y-axis
- **Double-tap**: Reset diagram to original state

### Visual Feedback  
- **Selection**: Yellow outline material on selected diagrams
- **Surface Planes**: Color-coded visualization (floor=blue, wall=green, etc.)
- **AR Coaching**: Built-in ARKit coaching overlay for setup

## Platform Conditional Code

The codebase uses extensive platform conditionals:

```swift
#if os(visionOS)
    // visionOS-specific ARKit and immersive space code
#elseif os(iOS)  
    // iOS-specific ARKit and camera overlay code
#endif
```

Key shared components work identically on both platforms:
- GroupActivities collaborative sessions
- HTTP server for remote diagrams
- JSON data models and parsing
- Diagram positioning algorithms

## Setup Instructions

### Adding iOS Target (if needed)

1. In Xcode, select the project root
2. Click "+" to add a new target  
3. Choose "iOS" → "App"
4. Name it "AVAR2-iOS"
5. Set deployment target to iOS 16.0+
6. Enable ARKit capability

### Required Info.plist Keys (iOS)

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to detect surfaces for anchoring 3D content in your environment.</string>

<key>NSSupportsGroupActivities</key>
<true/>

<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>arkit</string>
</array>
```

### Build Configuration

Ensure these files are included in iOS target:
- `iOSApp.swift` (iOS only)
- `iOSARKitManager.swift` (iOS only)  
- `iOSARViewContainer.swift` (iOS only)
- `iOSContentView.swift` (iOS only)
- All shared components

Exclude from iOS target:
- visionOS-specific ARKit files
- Immersive space components

## Testing

### Physical Device Testing
- iOS collaborative features require physical iPhone/iPad (ARKit limitation)
- visionOS collaborative features require physical Apple Vision Pro
- Cross-platform collaboration works between real devices

### Simulator Testing  
- Use debug mode to test collaborative UI states
- ARKit features won't work in iOS Simulator
- HTTP server and diagram loading can be tested

## Performance Considerations

### iOS Optimizations
- Diagrams scaled down 70% for mobile viewing (`scaleFactor = 0.3`)
- Simplified materials for better frame rate
- Entity pooling for large diagrams
- Occlusion culling with detected surfaces

### Memory Management
- Automatic cleanup of removed diagrams
- Entity component recycling
- Texture memory optimization

## Known Limitations

1. **iOS ARKit**: No immersive space equivalent - uses camera overlay
2. **Gesture Conflicts**: Complex gestures may interfere with each other
3. **Performance**: Mobile GPUs less powerful than visionOS
4. **Screen Real Estate**: Limited space for UI controls on phone screens

## Future Enhancements

1. **iPad Optimizations**: Larger UI layout for tablets  
2. **Apple Pencil Support**: Precision 3D manipulation
3. **Handoff**: Start on iPhone, continue on Vision Pro
4. **Cloud Sync**: Diagram persistence across devices
5. **Voice Commands**: Siri integration for hands-free control