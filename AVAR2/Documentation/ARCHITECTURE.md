# AVAR2 - Architecture Documentation

## Overview

AVAR2 is a visionOS application for displaying and interacting with 3D/2D data visualizations in augmented reality. The app uses ARKit for surface detection and RealityKit for rendering interactive 3D diagrams that can be positioned, scaled, and snapped to real-world surfaces.

> **📊 Architecture Diagrams**: All visual diagrams referenced in this document can be found in [ARCHITECTURE_DIAGRAMS.md](./ARCHITECTURE_DIAGRAMS.md)

## System Architecture

### High-Level Architecture

The system follows a layered architecture with clear separation of concerns:

- **User Interface Layer**: SwiftUI views and RealityKit integration
- **View Model Layer**: Business logic and state management  
- **Service Layer**: Data loading and AR functionality
- **Data Layer**: Models and factories for content generation

*See [High-Level System Architecture diagram](./ARCHITECTURE_DIAGRAMS.md#high-level-system-architecture) for visual representation.*

### Component Architecture

The application uses an MVVM pattern with the following key components:

- **AVAR2App**: Application entry point and lifecycle management
- **ContentView**: Primary UI view with RealityView integration
- **AppModel**: Global state management and surface detection coordination
- **ElementViewModel**: Diagram rendering and interaction logic
- **ARKitSurfaceDetector**: Real-world surface detection service
- **ElementService**: Data loading and parsing service
- **ElementDTO**: Data transfer objects for diagram elements

*See [Component Class Diagram](./ARCHITECTURE_DIAGRAMS.md#component-class-diagram) for detailed relationships.*

## Core Components

### 1. Application Layer

#### AVAR2App
- **Purpose**: Main application entry point
- **Responsibilities**:
  - App lifecycle management
  - Global state initialization
  - Immersive space management

#### ContentView
- **Purpose**: Primary UI view for displaying diagrams
- **Responsibilities**:
  - RealityView integration
  - Gesture handling orchestration
  - Error presentation

### 2. Business Logic Layer

#### AppModel
- **Purpose**: Global application state management
- **Key Features**:
  - Persistent surface detection coordination
  - Diagram positioning management
  - Debug visualization controls

#### ElementViewModel
- **Purpose**: Diagram rendering and interaction logic
- **Responsibilities**:
  - Data loading and processing
  - 3D entity creation and management
  - User interaction handling (pan, drag, zoom)
  - Surface snapping logic
  - Connection line rendering

### 3. Service Layer

#### ElementService
- **Purpose**: Data loading and parsing
- **Capabilities**:
  - JSON/TXT file loading from bundle
  - ScriptOutput deserialization
  - Error handling for missing files

#### ARKitSurfaceDetector
- **Purpose**: Real-world surface detection
- **Features**:
  - Horizontal and vertical plane detection
  - Surface classification (wall, floor, table, etc.)
  - Visual debugging overlays
  - Persistent anchor management

### 4. Data Layer

#### ElementDTO
- **Purpose**: Data transfer object for diagram elements
- **Properties**:
  - Geometric data (position, size)
  - Visual properties (color, shape)
  - Relationship data (connections)

#### ShapeFactory
- **Purpose**: 3D mesh and material generation
- **Capabilities**:
  - Multiple shape types (cube, sphere, cylinder, etc.)
  - 2D RT shapes (boxes, ellipses, labels)
  - Normalization and scaling
  - Material creation

## Data Flow

### Diagram Loading Flow

The diagram loading process follows these key steps:

1. **Data Loading**: ContentView triggers data loading from ElementViewModel
2. **File Processing**: ElementService loads and parses JSON/TXT files
3. **Data Transformation**: Elements are decoded into ElementDTO objects
4. **Normalization**: A NormalizationContext is created for scaling
5. **Scene Setup**: Root container and background entities are created
6. **UI Controls**: Close, grab, and zoom handles are added
7. **Entity Creation**: Each element is converted to a 3D entity via ShapeFactory
8. **Scene Assembly**: Entities are positioned and added to the scene
9. **Connections**: Lines between connected elements are drawn
10. **Finalization**: Origin markers and debug elements are added

*See [Diagram Loading Sequence](./ARCHITECTURE_DIAGRAMS.md#diagram-loading-sequence) for detailed flow.*

### Interaction Flow

User interactions follow a consistent pattern:

1. **Gesture Recognition**: ContentView captures user gestures
2. **Gesture Processing**: ElementViewModel processes gesture data
3. **Position Calculation**: New positions are calculated based on gesture
4. **Surface Detection**: AppModel provides available surface anchors
5. **Snapping Logic**: Nearest suitable surfaces are identified
6. **Visual Feedback**: Snap messages and previews are shown
7. **Animation**: Final positions are applied with smooth transitions
8. **State Update**: Internal state is updated to reflect changes

*See [User Interaction Sequence](./ARCHITECTURE_DIAGRAMS.md#user-interaction-sequence) for detailed flow.*

## Key Design Patterns

### 1. MVVM (Model-View-ViewModel)
- **View**: ContentView, SwiftUI components
- **ViewModel**: ElementViewModel, AppModel
- **Model**: ElementDTO, surface anchors

### 2. Observer Pattern
- SwiftUI's `@Published` and `@StateObject`
- Real-time updates for surface detection
- UI state synchronization

### 3. Factory Pattern
- ShapeFactory for mesh generation
- Centralized object creation logic
- Extensible shape type system

### 4. Service Layer Pattern
- ElementService for data operations
- ARKitSurfaceDetector for AR operations
- Separation of concerns

### 5. Strategy Pattern
- Different snapping behaviors for surface types
- Shape-specific mesh generation
- Gesture handling variations

## Surface Snapping System

### Snapping Logic

The surface snapping system intelligently attaches diagrams to real-world surfaces based on diagram type and surface characteristics:

**Process Flow:**
1. **Pan Detection**: System detects when user is panning a diagram
2. **Surface Retrieval**: Gets all available surfaces from ARKitSurfaceDetector
3. **Type-Based Filtering**: 
   - 2D diagrams → Vertical surfaces (walls)
   - 3D diagrams → Horizontal surfaces (floors, tables, ceilings)
4. **Distance Calculation**: Calculates distance to each valid surface
5. **Threshold Checking**: Determines if diagram is within snapping range
6. **Visual Feedback**: Shows preview messages when snap is available
7. **Snap Execution**: Performs smooth animation to final position when gesture ends
8. **Surface Binding**: Maintains reference to snapped surface for future interactions

*See [Surface Snapping Logic Flowchart](./ARCHITECTURE_DIAGRAMS.md#surface-snapping-logic-flowchart) for detailed decision tree.*

### Surface Classification

Different surface types require different snapping behaviors:

**Wall Snapping (2D Diagrams):**
- Position diagram perpendicular to wall surface
- Rotate to align with wall normal
- Maintain small offset from surface

**Floor/Table Snapping (3D Diagrams):**
- Position diagram above surface
- Calculate offset based on lowest entity bounds
- Maintain upright orientation

**Ceiling Snapping (3D Diagrams):**
- Position diagram below surface
- Calculate offset based on highest entity bounds  
- Rotate diagram upside down for ceiling mounting

**Unknown Surface Handling:**
- Detect orientation (vertical vs horizontal)
- Apply appropriate snapping behavior
- Fallback to generic positioning if unclear

*See [Surface Classification and Snapping](./ARCHITECTURE_DIAGRAMS.md#surface-classification-and-snapping) for visual representation.*

## Entity Hierarchy

### Scene Graph Structure

The 3D scene is organized in a hierarchical structure for efficient rendering and interaction:

**Top Level:**
- **RealityViewContent**: SwiftUI's RealityKit integration root
- **Graph Root Container**: Main container for all diagram content

**Container Children:**
- **Background Entity**: Invisible collision volume for gesture capture
- **Element Entities**: Individual diagram elements (nodes, shapes)
- **Connection Lines**: Lines connecting related elements
- **Origin Marker**: Debug sphere showing diagram center

**UI Controls (Children of Background):**
- **Close Button**: Dismisses the diagram
- **Grab Handle**: Enables diagram panning and repositioning  
- **Zoom Handle**: Enables diagram scaling

**Element Details (Children of Elements):**
- **Element Geometry**: 3D mesh (cube, sphere, cylinder, etc.)
- **Element Labels**: Text labels for identification

This hierarchy enables:
- Efficient culling and rendering
- Grouped transformations (move/scale entire diagram)
- Isolated interaction handling
- Clean resource management

*See [Entity Hierarchy and Scene Graph](./ARCHITECTURE_DIAGRAMS.md#entity-hierarchy-and-scene-graph) for visual structure.*

## Gesture System

### Gesture Handling Architecture

The gesture system uses a state machine approach to handle different types of user interactions:

**Primary States:**
- **Idle**: No active gestures, waiting for user input
- **ElementDrag**: Dragging individual diagram elements (3D only)
- **WindowPan**: Moving entire diagram via grab handle
- **WindowZoom**: Scaling diagram via zoom handle
- **SurfaceSnapping**: Showing snap preview during pan
- **Snapped**: Diagram attached to a real-world surface
- **ButtonTap**: Handling UI button interactions

**State Transitions:**
- Touch detection determines initial state
- Gesture continuation maintains current state
- Proximity to surfaces triggers snapping preview
- Gesture completion returns to idle or snapped state

**Gesture Processing:**
1. **Input Recognition**: ContentView captures raw gesture data
2. **State Evaluation**: Current state determines processing method
3. **Coordinate Transformation**: Gestures converted to 3D space
4. **Constraint Application**: Movements constrained by context
5. **Visual Update**: Immediate visual feedback during gesture
6. **State Persistence**: Final state stored for next interaction

*See [Gesture State Machine](./ARCHITECTURE_DIAGRAMS.md#gesture-state-machine) for detailed state transitions.*

## Performance Considerations

### Optimization Strategies

1. **Entity Pooling**: Reuse entities when possible
2. **Lazy Loading**: Load diagrams on demand
3. **Level of Detail**: Simplify distant objects
4. **Culling**: Hide off-screen entities
5. **Batch Operations**: Group similar operations

### Memory Management

- Weak references to prevent retain cycles
- Automatic cleanup of removed entities
- Efficient anchor management
- Resource disposal on view disappearance

## Extension Points

### Adding New Shape Types

1. Extend `ShapeFactory` with new creation methods
2. Update `ElementDTO.meshAndMaterial()` logic
3. Add corresponding shape descriptions in data files

### Adding New Interaction Types

1. Extend gesture recognition in `ContentView`
2. Add new handler methods in `ElementViewModel`
3. Implement state management for new interactions

### Adding New Surface Types

1. Extend `PlaneAnchor.Classification` handling
2. Update surface filtering logic
3. Implement specific snapping behavior

## Testing Strategy

### Unit Testing
- Individual component logic
- Data transformation functions
- Gesture calculations
- Surface detection algorithms

### Integration Testing
- View-ViewModel interactions
- Service layer integration
- AR session management

### Visual Testing
- 3D rendering correctness
- UI layout verification
- Animation smoothness
- Cross-device compatibility

## Dependencies

### External Frameworks
- **SwiftUI**: UI framework
- **RealityKit**: 3D rendering and AR
- **ARKit**: Surface detection and tracking
- **simd**: Mathematical operations
- **OSLog**: Logging and debugging

### Internal Dependencies
- Modular component architecture
- Clear separation of concerns
- Minimal coupling between layers

## Security Considerations

- No sensitive data processing
- Local file access only
- AR permissions properly managed
- User privacy respected (no data collection)

## Future Enhancements

### Planned Features
1. **Multi-user Collaboration**: Shared AR experiences
2. **Advanced Gestures**: Pinch-to-zoom, rotation
3. **Custom Shaders**: Enhanced visual effects
4. **Export Functionality**: Save/share diagrams
5. **Voice Commands**: Accessibility improvements

### Technical Debt
1. Refactor remaining long methods
2. Implement comprehensive error recovery
3. Add performance monitoring
4. Enhance logging system
5. Improve test coverage

---

*This document serves as a living reference for the AVAR2 architecture and should be updated as the system evolves.*