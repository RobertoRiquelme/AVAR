# AVAR2 Collaborative Sessions - API Reference

## CollaborativeSessionManager

### Overview
Main controller for managing RealityKit collaborative sessions and GroupActivity integration.

### Properties

```swift
@Published var isInCollaborativeSession: Bool
```
- **Description**: Current collaboration session state
- **Type**: `Bool`
- **Default**: `false`
- **Usage**: Reactive property for UI updates

```swift
@Published var sessionParticipantCount: Int
```
- **Description**: Number of active participants in current session
- **Type**: `Int`
- **Default**: `0`
- **Usage**: Display participant count in UI

```swift
@Published var sessionState: String
```
- **Description**: Human-readable session status
- **Type**: `String`
- **Values**: `"Not Connected"`, `"Joined"`, `"Waiting for participants..."`, `"Connected (X participants)"`

### Methods

#### Session Management

```swift
func startCollaboration() async
```
- **Description**: Initiates a new collaborative session
- **Returns**: `Void`
- **Throws**: May throw GroupActivity errors
- **Example**:
```swift
Task {
    await collaborativeManager.startCollaboration()
}
```

```swift
func endCollaboration()
```
- **Description**: Ends current collaborative session and cleans up resources
- **Returns**: `Void`
- **Side Effects**: Resets session state, removes all participants

#### Entity Synchronization

```swift
func makeEntityCollaborative(_ entity: Entity, identifier: String)
```
- **Description**: Enables automatic synchronization for a RealityKit entity
- **Parameters**:
  - `entity`: The RealityKit entity to make collaborative
  - `identifier`: Unique identifier for cross-participant synchronization
- **Example**:
```swift
let entity = ModelEntity(...)
collaborativeManager.makeEntityCollaborative(entity, identifier: "diagram_main")
```

```swift
func removeEntityFromCollaboration(_ entity: Entity)
```
- **Description**: Removes collaborative behavior from an entity
- **Parameters**:
  - `entity`: The entity to remove from collaboration

#### Data Synchronization

```swift
func sendDiagram(_ filename: String, jsonData: String, position: SIMD3<Float>)
```
- **Description**: Sends complete diagram data to all participants
- **Parameters**:
  - `filename`: Identifier for the diagram
  - `jsonData`: JSON representation of diagram data
  - `position`: Initial position in 3D space
- **Example**:
```swift
collaborativeManager.sendDiagram("myDiagram", jsonData: jsonString, position: [0, 1, -2])
```

```swift
func sendDiagramPosition(_ filename: String, position: SIMD3<Float>)
```
- **Description**: Sends position update for existing diagram
- **Parameters**:
  - `filename`: Identifier of diagram to update
  - `position`: New position in 3D space

```swift
func sendImmersionLevel(_ level: Double)
```
- **Description**: Broadcasts immersion level change to participants
- **Parameters**:
  - `level`: Immersion level (0.0 to 1.0)

### Callbacks

```swift
var onDiagramReceived: ((DiagramData) -> Void)?
```
- **Description**: Called when diagram data is received from other participants
- **Parameter**: `DiagramData` object containing diagram information

```swift
var onDiagramPositionUpdated: ((String, SIMD3<Float>) -> Void)?
```
- **Description**: Called when diagram position is updated by other participants
- **Parameters**:
  - `String`: Diagram filename
  - `SIMD3<Float>`: New position

```swift
var onImmersionLevelReceived: ((Double) -> Void)?
```
- **Description**: Called when other participants change immersion level
- **Parameter**: `Double` immersion level (0.0 to 1.0)

---

## DiagramSyncService

### Overview
Handles messaging and data synchronization between collaborative session participants.

### Methods

```swift
func configure(with session: GroupSession<DiagramActivity>)
```
- **Description**: Configures service with active GroupActivity session
- **Parameters**:
  - `session`: Active GroupSession for messaging

```swift
func sendDiagram(_ diagramData: DiagramData)
```
- **Description**: Sends diagram data using reliable messaging
- **Parameters**:
  - `diagramData`: Complete diagram data structure

```swift
func disconnect()
```
- **Description**: Cleans up messaging resources

### Data Structures

#### DiagramData
```swift
struct DiagramData: Codable, Identifiable {
    let id: String
    let filename: String
    let jsonData: String
    let position: DiagramPosition
    let timestamp: Date
}
```

#### DiagramPositionUpdate
```swift
struct DiagramPositionUpdate: Codable {
    let filename: String
    let position: DiagramPosition
    let timestamp: Date
}
```

#### DiagramPosition
```swift
struct DiagramPosition: Codable {
    let x: Float
    let y: Float  
    let z: Float
    
    var simd: SIMD3<Float> { 
        SIMD3<Float>(x, y, z) 
    }
}
```

---

## CollaborativeSessionModifier

### Overview
SwiftUI ViewModifier for integrating collaborative sessions with RealityView.

### Usage

```swift
extension View {
    func enableCollaborativeSession(onSessionChange: ((Bool) -> Void)? = nil) -> some View
}
```
- **Description**: Enables collaborative sessions for RealityView
- **Parameters**:
  - `onSessionChange`: Optional callback for session state changes
- **Returns**: Modified view with collaborative support

### Example
```swift
RealityView { content in
    // RealityKit content setup
} update: { content in
    // RealityKit updates
}
.enableCollaborativeSession { isActive in
    print("Collaboration active: \(isActive)")
}
```

---

## Entity Extensions

### Overview
Extensions for making RealityKit entities collaborative.

```swift
extension Entity {
    func makeCollaborative(with manager: CollaborativeSessionManager, identifier: String)
    func removeFromCollaboration(with manager: CollaborativeSessionManager)
}
```

### Usage
```swift
let entity = ModelEntity(...)
entity.makeCollaborative(with: collaborativeManager, identifier: "unique_id")

// Later, to remove from collaboration:
entity.removeFromCollaboration(with: collaborativeManager)
```

---

## Environment Values

### CollaborativeSessionManager Access

```swift
@Environment(\.collaborativeSessionManager) private var collaborativeManager
```
- **Description**: Access collaborative session manager from SwiftUI views
- **Type**: `CollaborativeSessionManager?`
- **Usage**: Available in views using `enableCollaborativeSession` modifier

---

## Message Types

### DiagramMessage
```swift
enum DiagramMessage: Codable {
    case diagramData(DiagramData)
    case positionUpdate(DiagramPositionUpdate)  
    case immersionLevel(Double)
}
```

### Message Handling
Messages are automatically handled by `DiagramSyncService` and trigger appropriate callbacks.

---

## Error Handling

### Common Errors
- `GroupActivity activation failed`: Check permissions and network connectivity
- `Entity synchronization failed`: Verify entity has proper identifier
- `Message delivery failed`: Check network connectivity

### Logging
All collaborative features use structured logging:
```swift
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "Component")
```

### Log Categories
- `CollaborativeSessionManager`: Session lifecycle
- `DiagramSyncService`: Message delivery
- `CollaborativeSessionModifier`: UI integration

---

## Best Practices

### Entity Identifiers
Use descriptive, unique identifiers:
```swift
// Good
"diagram_\(diagramName)_container"
"element_\(diagramName)_\(elementId)"

// Avoid
"entity1"
"temp"
```

### Memory Management
Always clean up when ending sessions:
```swift
// Automatic cleanup
collaborativeManager.endCollaboration()

// Manual entity cleanup if needed
entity.removeFromCollaboration(with: collaborativeManager)
```

### Performance Considerations
- Only make entities collaborative when necessary
- Use position updates for frequent changes
- Batch multiple entity updates when possible

### Error Recovery
```swift
collaborativeManager.onDiagramReceived = { diagramData in
    do {
        // Process diagram data
        try processDiagram(diagramData)
    } catch {
        logger.error("Failed to process collaborative diagram: \(error)")
        // Implement fallback behavior
    }
}
```

---

## Integration Examples

### Basic Setup
```swift
struct MyView: View {
    @State private var collaborativeManager = CollaborativeSessionManager()
    
    var body: some View {
        RealityView { content in
            // Setup entities
        }
        .enableCollaborativeSession()
        .environment(collaborativeManager)
    }
}
```

### Advanced Integration
```swift
class DiagramController: ObservableObject {
    private var collaborativeManager: CollaborativeSessionManager?
    
    func setupCollaboration(_ manager: CollaborativeSessionManager) {
        self.collaborativeManager = manager
        
        manager.onDiagramReceived = { [weak self] diagramData in
            self?.handleIncomingDiagram(diagramData)
        }
        
        manager.onDiagramPositionUpdated = { [weak self] filename, position in
            self?.updateDiagramPosition(filename, position)
        }
    }
    
    func shareCurrentDiagram() {
        guard let manager = collaborativeManager,
              let diagramData = getCurrentDiagramData() else { return }
        
        manager.sendDiagram(
            diagramData.filename,
            jsonData: diagramData.json,
            position: diagramData.position
        )
    }
}
```