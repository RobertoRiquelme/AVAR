//
//  AppModel.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import OSLog

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.open

    // Simple ARKit surface detector
    let surfaceDetector = ARKitSurfaceDetector()
    private var surfaceDetectionStarted = false

    // Debug: plane visualization toggle (start disabled)
    var showPlaneVisualization = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "AppModel")
    private let isVerboseLoggingEnabled = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil

    // Dynamic positioning for multiple diagrams (keep content near the user)
    private let layoutCoordinatorMaxRadius = 20
    private var layoutCoordinator = DiagramLayoutCoordinator(
        spacing: WorldPlacementConfiguration.default.gridSpacing,
        skipBehindUser: true,
        maxSearchRadius: 20
    )

    var worldPlacement: WorldPlacementConfiguration = .default {
        didSet {
            layoutCoordinator = DiagramLayoutCoordinator(
                spacing: worldPlacement.gridSpacing,
                skipBehindUser: true,
                maxSearchRadius: layoutCoordinatorMaxRadius
            )
        }
    }

    // Default scale used when spawning diagrams (30% smaller than previous default)
    let defaultDiagramScale: Float = PlatformConfiguration.diagramScale * 0.7

    // Track active diagrams by ID for updates/redraw
    private var activeDiagrams: [Int: Int] = [:] // id -> diagram index
    private var diagramFiles: [Int: String] = [:] // id -> filename
    
    func startSurfaceDetectionIfNeeded() async {
        guard !surfaceDetectionStarted else { 
            if self.isVerboseLoggingEnabled {
                self.logger.debug("🚫 Surface detection already started - skipping")
            }
            return 
        }
        if self.isVerboseLoggingEnabled {
            self.logger.debug("🚀 Starting ONE-TIME surface detection for entire app session...")
        }
        surfaceDetectionStarted = true
        await surfaceDetector.run()
    }
    
    /// Force restart surface detection (use carefully)
    func restartSurfaceDetection() async {
        self.logger.info("🔄 Force restarting surface detection...")
        surfaceDetectionStarted = false
        await startSurfaceDetectionIfNeeded()
    }
    
    /// Get the next position for a diagram, filling nearby grid slots before moving far away
    func getNextDiagramPosition(for filename: String) -> SIMD3<Float> {
        let basePosition = SIMD3<Float>(0, worldPlacement.eyeLevel, worldPlacement.frontOffset)

        let position = layoutCoordinator.position(for: filename, basePosition: basePosition)
        if let slot = layoutCoordinator.slot(for: filename) {
            if self.isVerboseLoggingEnabled {
                self.logger.debug("📍 Diagram position for \(filename, privacy: .public): \(String(describing: position), privacy: .public) (slot: \(String(describing: slot), privacy: .public))")
            }
        } else if self.isVerboseLoggingEnabled {
            self.logger.debug("📍 Diagram position for \(filename, privacy: .public): \(String(describing: position), privacy: .public) (slot: none)")
        }
        if self.isVerboseLoggingEnabled {
            self.logger.debug("🔢 Occupied slots: \(self.layoutCoordinatorOccupancyCount(), privacy: .public) | Stored diagrams: \(self.layoutCoordinatorStoredCount(), privacy: .public)")
            self.logger.debug("🔍 Surface detection status: running=\(self.surfaceDetector.isRunning, privacy: .public), anchors=\(self.surfaceDetector.surfaceAnchors.count, privacy: .public)")
        }
        return position
    }

    /// Get the current position of an existing diagram (returns nil if not found)
    func getDiagramPosition(for filename: String) -> SIMD3<Float>? {
        let basePosition = SIMD3<Float>(0, worldPlacement.eyeLevel, worldPlacement.frontOffset)
        // Check if this diagram has a slot assigned
        if layoutCoordinator.slot(for: filename) != nil {
            return layoutCoordinator.position(for: filename, basePosition: basePosition)
        }
        return nil
    }
    
    /// Register a diagram with ID for tracking
    func registerDiagram(id: Int, filename: String, index: Int) {
        activeDiagrams[id] = index
        diagramFiles[id] = filename
        self.logger.info("📝 Registered diagram id=\(id, privacy: .public) filename=\(filename, privacy: .public) index=\(index, privacy: .public)")
    }
    
    /// Check if diagram exists and get its info
    func getDiagramInfo(for id: Int) -> (filename: String, index: Int)? {
        guard let index = activeDiagrams[id],
              let filename = diagramFiles[id] else {
            return nil
        }
        return (filename: filename, index: index)
    }
    
    /// Remove diagram from tracking
    func removeDiagram(id: Int) {
        activeDiagrams.removeValue(forKey: id)
        diagramFiles.removeValue(forKey: id)
        if self.isVerboseLoggingEnabled {
            self.logger.debug("🗑️ Removed diagram id=\(id, privacy: .public)")
        }
    }
    
    /// Free up a position when diagram is removed
    func freeDiagramPosition(filename: String) {
        layoutCoordinator.release(filename: filename)
        if self.isVerboseLoggingEnabled {
            self.logger.debug("🆓 Freed slot for diagram: \(filename, privacy: .public)")
        }

        // Also remove from ID tracking if it exists
        for (id, storedFilename) in diagramFiles {
            if storedFilename == filename {
                removeDiagram(id: id)
                break
            }
        }
    }
    
    /// Reset diagram positioning (when exiting immersive space)
    func resetDiagramPositioning() {
        layoutCoordinator.reset()
        activeDiagrams.removeAll()
        diagramFiles.removeAll()
        self.logger.info("🔄 Reset diagram positioning")
    }

    /// Update the diagram placement configuration at runtime.
    func applyWorldPlacement(_ configuration: WorldPlacementConfiguration, resetPositions: Bool = true) {
        worldPlacement = configuration
        if resetPositions {
            resetDiagramPositioning()
        }
    }

    /// Toggle plane visualization for debugging
    func togglePlaneVisualization() {
        showPlaneVisualization.toggle()
        surfaceDetector.setVisualizationVisible(showPlaneVisualization)
        if self.isVerboseLoggingEnabled {
            self.logger.debug("🎨 Plane visualization: \(self.showPlaneVisualization ? "ON" : "OFF", privacy: .public)")
        }
    }
}

// MARK: - Debug helpers

private extension AppModel {
    func layoutCoordinatorOccupancyCount() -> Int {
        return layoutCoordinator.occupancyCount
    }

    func layoutCoordinatorStoredCount() -> Int {
        return layoutCoordinator.storedFilenameCount
    }
}
