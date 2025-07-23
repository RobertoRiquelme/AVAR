# AVAR2 - Architecture Diagrams

This document contains all the mermaid diagrams referenced in the main [ARCHITECTURE.md](./ARCHITECTURE.md) file.

## High-Level System Architecture

```mermaid
graph TB
    subgraph "User Interface Layer"
        A[AVAR2App] --> B[ContentView]
        B --> C[RealityView]
    end
    
    subgraph "View Model Layer"
        D[ElementViewModel]
        E[AppModel]
    end
    
    subgraph "Service Layer"
        F[ElementService]
        G[ARKitSurfaceDetector]
    end
    
    subgraph "Data Layer"
        H[ElementDTO]
        I[ShapeFactory]
        J[NormalizationContext]
    end
    
    subgraph "Resources"
        K[JSON/TXT Files]
        L[RealityKitContent]
    end
    
    C --> D
    C --> E
    D --> F
    D --> G
    E --> G
    F --> H
    H --> I
    H --> J
    F --> K
    C --> L
```

## Component Class Diagram

```mermaid
classDiagram
    class AVAR2App {
        +immersiveSpaceID: String
        +appModel: AppModel
        +main()
    }
    
    class ContentView {
        +filename: String
        +onClose: (() -> Void)?
        +viewModel: ElementViewModel
        +body: View
    }
    
    class AppModel {
        +immersiveSpaceState: ImmersiveSpaceState
        +surfaceDetector: ARKitSurfaceDetector
        +showPlaneVisualization: Bool
        +startSurfaceDetectionIfNeeded()
        +getNextDiagramPosition()
        +resetDiagramPositioning()
        +togglePlaneVisualization()
    }
    
    class ElementViewModel {
        +elements: [ElementDTO]
        +isGraph2D: Bool
        +loadErrorMessage: String?
        +loadData(from: String)
        +loadElements(in: RealityViewContent)
        +handlePanChanged()
        +handleDragChanged()
        +performSnapToSurface()
    }
    
    class ARKitSurfaceDetector {
        +surfaceAnchors: [PlaneAnchor]
        +isRunning: Bool
        +errorMessage: String?
        +run()
        +setVisualizationVisible()
    }
    
    class ElementService {
        +loadElements(from: String)
        +loadScriptOutput(from: String)
    }
    
    class ElementDTO {
        +id: String
        +position: [Double]?
        +color: [Double]?
        +shape: ShapeDTO?
        +fromId: String?
        +toId: String?
        +meshAndMaterial()
    }
    
    AVAR2App --> AppModel
    AVAR2App --> ContentView
    ContentView --> ElementViewModel
    ElementViewModel --> ElementService
    ElementViewModel --> ARKitSurfaceDetector
    AppModel --> ARKitSurfaceDetector
    ElementService --> ElementDTO
    ElementDTO --> ShapeFactory
```

## Diagram Loading Sequence

```mermaid
sequenceDiagram
    participant CV as ContentView
    participant VM as ElementViewModel
    participant ES as ElementService
    participant ED as ElementDTO
    participant SF as ShapeFactory
    participant RC as RealityContent
    
    CV->>VM: loadData(filename)
    VM->>ES: loadScriptOutput(filename)
    ES->>ED: decode JSON data
    ES-->>VM: return elements array
    VM->>VM: create NormalizationContext
    
    CV->>VM: loadElements(in: content)
    VM->>VM: setupSceneContent()
    VM->>VM: createRootContainer()
    VM->>VM: createBackgroundEntity()
    VM->>VM: setupUIControls()
    
    loop for each element
        VM->>ED: createEntity()
        ED->>SF: meshAndMaterial()
        SF-->>ED: return mesh + material
        ED-->>VM: return configured entity
        VM->>RC: add entity to scene
    end
    
    VM->>VM: updateConnections()
    VM->>VM: addOriginMarker()
```

## User Interaction Sequence

```mermaid
sequenceDiagram
    participant U as User
    participant CV as ContentView
    participant VM as ElementViewModel
    participant AM as AppModel
    participant SD as SurfaceDetector
    
    U->>CV: Pan gesture
    CV->>VM: handlePanChanged()
    VM->>VM: extractGestureOffset()
    VM->>VM: calculateNewPanPosition()
    VM->>VM: updateContainerPosition()
    VM->>VM: checkForSurfaceSnapping()
    VM->>AM: getAllSurfaceAnchors()
    AM->>SD: surfaceAnchors
    SD-->>AM: return anchors
    AM-->>VM: return anchors
    VM->>VM: findNearestSurfaceForSnapping()
    
    U->>CV: End pan gesture
    CV->>VM: handlePanEnded()
    VM->>VM: calculateFinalPanPosition()
    VM->>VM: animateToFinalPosition()
    VM->>VM: handleSurfaceSnappingOnPanEnd()
    VM->>VM: performSnapToSurface()
```

## Surface Snapping Logic Flowchart

```mermaid
flowchart TD
    A[User Pans Diagram] --> B{Is Pan Active?}
    B -->|Yes| C[Get Available Surfaces]
    C --> D[Filter by Diagram Type]
    D --> E{2D Diagram?}
    E -->|Yes| F[Filter Vertical Surfaces]
    E -->|No| G[Filter Horizontal Surfaces]
    F --> H[Calculate Distance to Each Surface]
    G --> H
    H --> I{Distance < Snap Threshold?}
    I -->|Yes| J[Show Snap Preview]
    I -->|No| K[Clear Snap Message]
    J --> L[Pan Gesture Ends]
    K --> L
    L --> M[Find Nearest Valid Surface]
    M --> N{Surface Found?}
    N -->|Yes| O[Perform Snap Animation]
    N -->|No| P[Apply Comfort Zone]
    O --> Q[Update Surface Reference]
    P --> Q
```

## Surface Classification and Snapping

```mermaid
graph LR
    A[PlaneAnchor] --> B{Classification}
    B -->|wall| C[Wall Snapping]
    B -->|floor| D[Floor Snapping]
    B -->|table| D
    B -->|ceiling| E[Ceiling Snapping]
    B -->|unknown| F{Detect Orientation}
    F -->|Vertical| C
    F -->|Horizontal| D
    
    C --> G[Position on surface normal<br/>Rotate to align with wall]
    D --> H[Position above surface<br/>Account for entity bounds]
    E --> I[Position below surface<br/>Rotate upside down]
```

## Entity Hierarchy and Scene Graph

```mermaid
graph TD
    A[RealityViewContent] --> B[Graph Root Container]
    B --> C[Background Entity]
    B --> D[Element Entities]
    B --> E[Connection Lines]
    B --> F[Origin Marker]
    
    C --> G[Close Button]
    C --> H[Grab Handle]
    C --> I[Zoom Handle]
    
    D --> J[Element Geometry]
    D --> K[Element Labels]
    
    subgraph "UI Controls"
        G
        H
        I
    end
    
    subgraph "Content"
        J
        K
        E
        F
    end
```

## Gesture State Machine

```mermaid
stateDiagram-v2
    [*] --> Idle
    
    Idle --> ElementDrag : Tap on element
    Idle --> WindowPan : Tap on grab handle
    Idle --> WindowZoom : Tap on zoom handle
    Idle --> ButtonTap : Tap on close button
    
    ElementDrag --> ElementDrag : Drag continues
    ElementDrag --> Idle : Drag ends
    
    WindowPan --> WindowPan : Pan continues
    WindowPan --> SurfaceSnapping : Near surface
    WindowPan --> Idle : Pan ends
    
    SurfaceSnapping --> WindowPan : Move away from surface
    SurfaceSnapping --> Snapped : Release near surface
    
    Snapped --> WindowPan : Start new pan
    Snapped --> Idle : No interaction
    
    WindowZoom --> WindowZoom : Zoom continues
    WindowZoom --> Idle : Zoom ends
    
    ButtonTap --> [*] : Close diagram
```

---

*These diagrams provide visual representations of the AVAR2 architecture and can be rendered in any mermaid-compatible viewer.*