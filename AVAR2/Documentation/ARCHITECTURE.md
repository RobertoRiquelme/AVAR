# AVAR2 - Architecture Documentation

## Overview

AVAR2 is a multi-platform (visionOS and iOS) application for displaying and interacting with 3D/2D data visualizations in augmented reality. The app uses ARKit for surface detection, RealityKit for rendering interactive 3D diagrams, SharePlay for collaborative experiences, and includes an HTTP server for remote diagram loading. Diagrams can be positioned, scaled, and snapped to real-world surfaces.

> **📊 Architecture Diagrams**: All visual diagrams referenced in this document can be found in [ARCHITECTURE_DIAGRAMS.md](./ARCHITECTURE_DIAGRAMS.md)

## System Architecture

### High-Level Architecture

The system follows a layered architecture with clear separation of concerns:

- **User Interface Layer**: Platform-specific SwiftUI views (visionOS/iOS) and RealityKit integration
- **View Model Layer**: Business logic, state management, and collaboration coordination
- **Service Layer**: Data loading, HTTP server, AR functionality, and surface detection
- **Data Layer**: Models, DTOs, and factories for content generation
- **Networking Layer**: HTTP server and SharePlay integration

*See [High-Level System Architecture diagram](./ARCHITECTURE_DIAGRAMS.md#high-level-system-architecture) for visual representation.*

### Component Architecture

The application uses an MVVM pattern with the following key components:

- **PlatformApp**: Main application entry point with platform-specific UI (visionOS/iOS)
- **AVAR2App**: Shared UI components and views (HTTP server tab, immersive wrapper, FPS monitor)
- **ContentView**: Primary UI view with RealityView integration for individual diagrams
- **AppModel**: Global state management, surface detection coordination, and diagram positioning
- **ElementViewModel**: Diagram rendering, interaction logic, and scene management
- **HTTPServer**: Local HTTP server for receiving diagram data from external sources
- **CollaborativeSessionManager**: SharePlay integration and spatial anchor sharing
- **SurfaceDetector**: Real-world surface detection service (ARKit on visionOS)
- **ElementService**: Data loading and parsing from bundle and shared storage
- **DiagramStorage**: Shared file storage for HTTP-received diagrams
- **ElementDTO**: Data transfer objects for diagram elements

*See [Component Class Diagram](./ARCHITECTURE_DIAGRAMS.md#component-class-diagram) for detailed relationships.*

## Core Components

### 1. Application Layer

#### PlatformApp
- **Purpose**: Main application entry point (@main)
- **Responsibilities**:
  - Platform-specific UI routing (visionOS vs iOS)
  - App lifecycle management
  - Immersive space management

#### VisionOSMainView
- **Purpose**: Launcher window for visionOS
- **Responsibilities**:
  - Input mode selection (File, JSON, HTTP Server)
  - HTTP server controls
  - Collaborative session management
  - Immersion controls
  - Diagram loading interface

#### VisionOSImmersiveView
- **Purpose**: Immersive space container for visionOS
- **Responsibilities**:
  - Wraps ImmersiveSpaceWrapper
  - Manages immersion style (mixed/full)
  - Displays collaborative session indicators

#### AVAR2App (Shared Components)
- **Purpose**: Reusable UI components across platform-specific views
- **Components**:
  - HTTPServerTabView: Server control UI
  - ImmersiveSpaceWrapper: Background and content management
  - StaticSurfaceView: Plane detection visualization
  - FPSMonitor: Performance monitoring

#### ContentView
- **Purpose**: RealityView container for individual diagrams
- **Responsibilities**:
  - RealityView integration per diagram
  - Gesture handling orchestration
  - Error presentation
  - Collaborative diagram synchronization

### 2. Business Logic Layer

#### AppModel
- **Purpose**: Global application state management
- **Key Features**:
  - Persistent surface detection coordination
  - Intelligent diagram positioning (grid layout, surface snapping)
  - Diagram tracking with ID-based updates
  - Debug visualization controls
  - Multi-diagram state management

#### ElementViewModel
- **Purpose**: Diagram rendering and interaction logic (per-diagram instance)
- **Responsibilities**:
  - Data loading from files or HTTP
  - 3D entity creation and management
  - User interaction handling (pan, drag, zoom)
  - Surface snapping logic
  - Connection line rendering
  - Scene rebuilding and updates
  - Collaborative position synchronization

#### CollaborativeSessionManager
- **Purpose**: Multi-user session coordination
- **Key Features**:
  - SharePlay GroupActivity integration
  - Spatial anchor broadcasting and synchronization
  - Diagram sharing across devices
  - Participant tracking
  - Message passing for real-time updates

### 3. Service Layer

#### ElementService
- **Purpose**: Data loading and parsing
- **Capabilities**:
  - JSON/TXT file loading from bundle
  - Loading from shared app group storage (HTTP diagrams)
  - Loading from temporary directory (manual JSON)
  - ScriptOutput deserialization
  - Error handling for missing files

#### DiagramDataLoader
- **Purpose**: Centralized diagram loading with error handling
- **Features**:
  - Consistent error messages
  - Verbose logging support (via AVAR_VERBOSE_LOGS)
  - Wraps ElementService calls

#### DiagramStorage
- **Purpose**: Shared file storage management
- **Features**:
  - App group container access
  - File URL generation
  - Shared directory creation
  - Cross-component file access

#### HTTPServer
- **Purpose**: Local HTTP server for remote diagram loading
- **Features**:
  - Socket-based server on port 8081
  - POST endpoint at `/avar`
  - JSON validation and parsing
  - Callback-based diagram notification
  - Real-time logging
  - Automatic diagram drawing on receipt

#### SurfaceDetector (formerly ARKitSurfaceDetector)
- **Purpose**: Real-world surface detection (visionOS only)
- **Features**:
  - Horizontal and vertical plane detection
  - Surface classification (wall, floor, table, etc.)
  - Visual debugging overlays
  - Persistent anchor management
  - Toggle visibility controls

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

### HTTP Server Diagram Flow

The HTTP server enables remote diagram loading with the following process:

1. **Server Start**: HTTPServer starts listening on port 8081
2. **Callback Registration**: VisionOSMainView.onAppear sets httpServer.onJSONReceived callback
3. **Request Receipt**: POST request arrives at `/avar` endpoint with JSON body
4. **JSON Validation**: Server validates JSON syntax
5. **Parsing**: JSONDecoder decodes into ScriptOutput
6. **Callback Invocation**: onJSONReceived closure called on main thread
7. **Immersive Space Check**: Ensures immersive space is open
8. **ID Check**: Examines diagram.id for update vs new diagram logic
9. **File Storage**: Saves JSON to DiagramStorage shared directory
10. **State Update**: Appends filename to activeFiles array
11. **SwiftUI Reaction**: ForEach creates ContentView for new file
12. **Scene Creation**: ElementViewModel loads and renders diagram

**Critical Fix**: The callback MUST be set in `.onAppear` (not `.task`) to ensure it's available before the first HTTP request arrives.

*See HTTP Server Sequence diagram for visual flow.*

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

## Platform-Specific Architecture

### visionOS
- **Full immersive experience** with mixed and full immersion modes
- **Surface detection** via ARKit for plane detection
- **Spatial anchors** for collaborative session alignment
- **RealityKit** for 3D rendering in immersive space
- **HTTP server** for remote diagram loading
- **Can share** diagrams in collaborative sessions

### iOS
- **AR companion mode** for collaborative sessions
- **Receive-only** for shared diagrams
- **No immersive space** (uses standard AR view)
- **No HTTP server** (not supported on iOS)
- **ARKit** for basic AR tracking

### Shared Components
- **SwiftUI** views from AVAR2App.swift
- **Data models** (ElementDTO, ScriptOutput)
- **CollaborativeSessionManager** (platform-aware)
- **Element rendering** logic in ElementViewModel

## Dependencies

### External Frameworks
- **SwiftUI**: UI framework
- **RealityKit**: 3D rendering and AR
- **ARKit**: Surface detection and tracking (visionOS/iOS)
- **GroupActivities**: SharePlay integration for collaboration
- **simd**: Mathematical operations
- **OSLog**: Logging and debugging
- **Network**: Socket-based HTTP server

### Internal Dependencies
- Modular component architecture
- Clear separation of concerns
- Minimal coupling between layers
- Platform-specific compilation directives (#if os(visionOS))

## Security Considerations

- **No sensitive data processing**: Diagrams are non-sensitive visualization data
- **Local network only**: HTTP server binds to local interfaces
- **No authentication**: HTTP server is designed for trusted local network use
- **File access**: Limited to app sandbox and shared app group container
- **AR permissions**: ARKit permissions properly requested and managed
- **User privacy**: No data collection, analytics, or external network calls
- **SharePlay**: Uses Apple's secure GroupActivities framework

## Future Enhancements

### Planned Features
1. **HTTP Server Authentication**: Add token-based authentication for remote access
2. **Advanced Gestures**: Enhanced pinch-to-zoom, multi-finger rotation
3. **Custom Shaders**: Enhanced visual effects and materials
4. **Export Functionality**: Save diagram layouts, export snapshots
5. **Voice Commands**: Accessibility improvements
6. **Persistent Diagrams**: Save diagram positions across app launches
7. **WebSocket Support**: Real-time bidirectional communication
8. **Diagram Animations**: Animated transitions between states

### Technical Debt
1. ~~Remove AVAR2_Legacy to avoid confusion~~ ✅ Completed
2. ~~Fix HTTP server callback timing issue~~ ✅ Completed (moved to .onAppear)
3. Add comprehensive unit tests for HTTP server
4. Refactor remaining long methods in ElementViewModel
5. Implement comprehensive error recovery for network failures
6. Add performance monitoring and profiling
7. Enhance logging system with structured logging
8. Improve test coverage for collaborative features
9. Document all public APIs
10. Add integration tests for SharePlay functionality

---

*This document serves as a living reference for the AVAR2 architecture and should be updated as the system evolves.*