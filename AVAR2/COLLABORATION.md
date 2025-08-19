# RealityKit Collaborative Sessions - AVAR2

## Overview

AVAR2 now supports real-time collaboration using RealityKit Collaborative Sessions, allowing multiple visionOS users to share and interact with 3D diagrams simultaneously in the same immersive space.

## Features

### 🔗 Core Collaboration
- **Multi-user sessions**: Support for multiple participants in the same collaborative space
- **Real-time synchronization**: Instant updates across all connected devices
- **Automatic entity sync**: 3D diagrams and their positions sync automatically
- **SharePlay integration**: Uses Apple's GroupActivity framework for native collaboration

### 📊 Diagram Synchronization
- **Diagram sharing**: New diagrams automatically appear on all participant devices
- **Position sync**: Moving diagrams updates positions for all users
- **Element-level sync**: Individual 3D elements sync position changes
- **Connection lines**: Diagram connections and relationships sync across participants

### 🌐 Input Method Support
- **File-based diagrams**: Dropdown selection syncs to all participants
- **JSON input**: Pasted JSON diagrams appear on all devices
- **HTTP server**: Remote diagram updates sync to collaborative session

### 🎛️ Immersion Control
- **Immersion notifications**: Participants see when others change immersion levels
- **Individual control**: Each user maintains their own immersion preference
- **Visual feedback**: Real-time immersion updates with smooth animations

## Architecture

### Core Components

#### 1. CollaborativeSessionManager
**File**: `CollaborativeSessionManager.swift`

```swift
@MainActor
@Observable 
class CollaborativeSessionManager {
    var isInCollaborativeSession: Bool
    var sessionParticipantCount: Int
    var sessionState: String
}
```

**Responsibilities**:
- Manages GroupActivity sessions
- Handles RealityKit synchronization service
- Provides callbacks for collaborative events
- Controls session lifecycle

**Key Methods**:
- `startCollaboration()`: Initiates a new collaborative session
- `endCollaboration()`: Leaves the current session
- `makeEntityCollaborative(_:identifier:)`: Enables sync for entities
- `sendDiagram(_:jsonData:position:)`: Shares diagram data
- `sendImmersionLevel(_:)`: Broadcasts immersion changes

#### 2. DiagramSyncService
**File**: `DiagramSyncService.swift`

```swift
@MainActor
@Observable
class DiagramSyncService {
    var onDiagramReceived: ((DiagramData) -> Void)?
    var onDiagramPositionUpdated: ((String, SIMD3<Float>) -> Void)?
    var onImmersionLevelReceived: ((Double) -> Void)?
}
```

**Responsibilities**:
- Handles messaging between participants
- Serializes and deserializes diagram data
- Manages reliable message delivery
- Provides type-safe message handling

**Message Types**:
- `DiagramMessage.diagramData`: Complete diagram with JSON and position
- `DiagramMessage.positionUpdate`: Position-only updates for existing diagrams
- `DiagramMessage.immersionLevel`: Immersion level changes

#### 3. CollaborativeSessionModifier
**File**: `CollaborativeSessionModifier.swift`

```swift
struct CollaborativeSessionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(collaborativeManager)
            .onChange(of: collaborativeManager.isInCollaborativeSession) { _, isActive in
                onSessionChange?(isActive)
            }
    }
}
```

**Responsibilities**:
- SwiftUI integration for RealityView
- Environment value propagation
- Session state change handling

**Usage**:
```swift
RealityView { content in
    // RealityKit content
}
.enableCollaborativeSession { isActive in
    print("Collaboration: \(isActive)")
}
```

## Integration Points

### 1. Main App Integration
**File**: `AVAR2App.swift`

**Changes Made**:
- Added `@State private var collaborativeManager = CollaborativeSessionManager()`
- Added collaboration UI controls in main window
- Integrated collaborative callbacks for incoming data
- Enhanced diagram addition to broadcast to participants
- Added immersion level broadcasting

**UI Components**:
```swift
// Collaborative Session Controls
VStack(spacing: 12) {
    Text("Collaboration")
        .font(.headline)
        .foregroundColor(.purple)
    
    HStack {
        if collaborativeManager.isInCollaborativeSession {
            Text(collaborativeManager.sessionState)
            Button("End Session") {
                collaborativeManager.endCollaboration()
            }
        } else {
            Button("Start Collaboration") {
                Task {
                    await collaborativeManager.startCollaboration()
                }
            }
        }
    }
}
```

### 2. ContentView Integration
**File**: `ContentView.swift`

**Changes Made**:
- Added `@Environment(\.collaborativeSessionManager)` access
- Enabled collaborative session modifier on RealityView
- Integrated collaborative manager with ElementViewModel

**RealityView Enhancement**:
```swift
RealityView { content in
    viewModel.loadElements(in: content, onClose: onClose)
} update: { content in
    viewModel.updateConnections(in: content)
}
.enableCollaborativeSession { isActive in
    print("📡 Collaborative session state changed: \(isActive)")
}
```

### 3. ElementViewModel Integration
**File**: `ElementViewModel.swift`

**Changes Made**:
- Added collaborative manager reference
- Enhanced entity creation to include collaborative components
- Made diagram containers, elements, and connections collaborative
- Added automatic entity synchronization

**Entity Synchronization**:
```swift
// Make individual elements collaborative
if let collaborativeManager = self.collaborativeManager {
    let collaborativeId = "\(filename ?? "unknown")_element_\(elementIdKey)"
    entity.makeCollaborative(with: collaborativeManager, identifier: collaborativeId)
}
```

### 4. AppModel Integration
**File**: `AppModel.swift`

**Changes Made**:
- Added collaborative session state tracking
- Added participant count tracking
- Enhanced with collaborative session state updates

**State Tracking**:
```swift
var isInCollaborativeSession: Bool = false
var collaborativeSessionParticipants: Int = 0

func updateCollaborativeSessionState(isActive: Bool, participantCount: Int = 0) {
    isInCollaborativeSession = isActive
    collaborativeSessionParticipants = participantCount
}
```

## Configuration

### 1. Info.plist Updates
**File**: `Info.plist`

```xml
<key>NSSupportsLiveActivities</key>
<true/>
<key>NSSupportsGroupActivities</key>
<true/>
```

**Purpose**: Enables GroupActivity support for collaborative sessions.

### 2. Import Dependencies
**Files**: Various Swift files

```swift
import GroupActivities
import Combine
```

**Purpose**: Provides access to collaborative session APIs and reactive programming support.

## Usage Guide

### Starting a Collaborative Session

1. **Launch the app** on multiple visionOS devices
2. **Open the main window** and locate the "Collaboration" section
3. **Tap "Start Collaboration"** on one device
4. **Other devices automatically detect** the session and can join
5. **Session status shows** "Connected (X participants)"

### Sharing Diagrams

#### Method 1: File Selection
1. Select a diagram from the dropdown
2. Tap "Add Diagram"
3. Diagram appears on all participant devices automatically

#### Method 2: JSON Input
1. Switch to "From JSON" tab
2. Paste JSON diagram data
3. Tap "Add Diagram"
4. JSON data syncs to all participants

#### Method 3: HTTP Server
1. Start the HTTP server
2. Send diagram data via HTTP POST
3. Received diagrams appear on all participant devices

### Collaborative Interactions

#### Position Synchronization
- **Drag diagrams**: Position changes sync in real-time
- **Scale diagrams**: Zoom handle interactions sync across devices
- **Rotate 3D diagrams**: Rotation button changes sync to all participants
- **Move individual elements**: Element position updates sync automatically

#### Immersion Control
- **Adjust immersion**: Use buttons or keyboard shortcuts
- **Broadcast changes**: Other participants see immersion notifications
- **Individual control**: Each user maintains their own immersion level

### Ending Collaboration
1. Tap "End Session" in the collaboration section
2. Session terminates for the leaving participant
3. Other participants continue in the session

## Technical Implementation Details

### Entity Synchronization

Each collaborative entity gets a unique identifier:
```swift
// Diagram containers
"diagram_\(diagramId)"

// Individual elements
"\(filename)_element_\(elementIdKey)"

// Connection lines
"\(filename)_line_\(fromId)_to_\(toId)"
```

### Message Delivery

- **Reliable delivery**: Diagram data uses reliable messaging
- **Ordered delivery**: Position updates maintain order
- **Error handling**: Comprehensive error handling with logging

### Performance Optimization

- **Conditional sync**: Only syncs when in active collaborative sessions
- **Efficient updates**: Only changed properties sync across network
- **Memory management**: Proper cleanup when sessions end

### Security Considerations

- **Local network**: Sessions work over local network or internet
- **Participant consent**: All participants must explicitly join sessions
- **Data privacy**: Diagram data only shared within active sessions

## Debugging and Logging

All collaborative features include comprehensive logging:

```swift
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "CollaborativeSessionManager")
```

**Log Categories**:
- `CollaborativeSessionManager`: Session lifecycle events
- `DiagramSyncService`: Message sending and receiving
- `CollaborativeSessionModifier`: UI integration events

**Key Log Messages**:
- `📡` Session state changes
- `🔗` Entity synchronization
- `📊` Diagram data transfer
- `🎛️` Immersion level updates
- `⚠️` Errors and warnings

## Troubleshooting

### Common Issues

1. **Session not starting**
   - Check GroupActivity permissions in Settings
   - Ensure devices are on same network or signed into same Apple ID
   - Verify Info.plist includes GroupActivity support

2. **Diagrams not syncing**
   - Check collaborative session is active
   - Verify entity has collaborative components
   - Check network connectivity

3. **Position updates delayed**
   - Network latency may cause delays
   - Check for error messages in console
   - Ensure proper entity identification

### Debug Commands

Enable verbose logging:
```swift
// Add to app initialization
os_log(.debug, "Collaborative session debug mode enabled")
```

## Future Enhancements

### Potential Features
- **Voice chat integration**: Add spatial audio communication
- **Gesture sharing**: Sync hand gesture interactions
- **Annotation system**: Add collaborative notes and markups
- **Session recording**: Save and replay collaborative sessions
- **Permission system**: Control who can modify diagrams
- **Persistent sessions**: Save and restore collaborative sessions

### API Extensions
- **Custom message types**: Support for application-specific data
- **Bandwidth optimization**: Compress large diagram data
- **Conflict resolution**: Handle simultaneous edits gracefully
- **User identification**: Show which participant made changes

## Conclusion

The RealityKit Collaborative Sessions implementation transforms AVAR2 into a powerful multi-user collaboration tool. Users can now share 3D diagrams, collaborate on positioning, and work together in immersive space with real-time synchronization across all connected visionOS devices.

The implementation follows Apple's best practices for visionOS collaboration and integrates seamlessly with existing features like surface detection, HTTP server input, and immersive space controls.