//
//  AppModel.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI

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

    // Dynamic positioning for multiple diagrams (keep content near the user)
    private struct GridSlot: Hashable {
        let x: Int
        let z: Int

        func offset(spacing: Float) -> SIMD3<Float> {
            SIMD3<Float>(Float(x) * spacing, 0, Float(z) * spacing)
        }
    }

    private let gridSpacing: Float = 0.9  // 90 cm steps keep diagrams within reach
    private var occupiedSlots: Set<GridSlot> = []
    private var filenameToSlot: [String: GridSlot] = [:]

    // Default scale used when spawning diagrams (30% smaller than previous default)
    let defaultDiagramScale: Float = PlatformConfiguration.diagramScale * 0.7

    // Track active diagrams by ID for updates/redraw
    private var activeDiagrams: [Int: Int] = [:] // id -> diagram index
    private var diagramFiles: [Int: String] = [:] // id -> filename
    
    func startSurfaceDetectionIfNeeded() async {
        guard !surfaceDetectionStarted else { 
            print("🚫 Surface detection already started - skipping")
            return 
        }
        print("🚀 Starting ONE-TIME surface detection for entire app session...")
        surfaceDetectionStarted = true
        await surfaceDetector.run()
    }
    
    /// Force restart surface detection (use carefully)
    func restartSurfaceDetection() async {
        print("🔄 Force restarting surface detection...")
        surfaceDetectionStarted = false
        await startSurfaceDetectionIfNeeded()
    }
    
    /// Get the next position for a diagram, filling nearby grid slots before moving far away
    func getNextDiagramPosition(for filename: String) -> SIMD3<Float> {
        let basePosition = SIMD3<Float>(0, 1.0, -2.0)  // Constants.eyeLevel, Constants.frontOffset

        if let existingSlot = filenameToSlot[filename] {
            occupiedSlots.insert(existingSlot)
            let position = basePosition + existingSlot.offset(spacing: gridSpacing)
            print("📍 Reusing diagram position: \(position) (slot: \(existingSlot)) for file: \(filename)")
            print("🔢 Occupied slots: \(occupiedSlots.count) | Stored diagrams: \(filenameToSlot.count)")
            print("🔍 Surface detection status: running=\(surfaceDetector.isRunning), anchors=\(surfaceDetector.surfaceAnchors.count)")
            return position
        }

        // Find the first available slot (closest to center)
        let nextSlot = findNextAvailableSlot()
        occupiedSlots.insert(nextSlot)
        filenameToSlot[filename] = nextSlot

        let offset = nextSlot.offset(spacing: gridSpacing)
        let position = basePosition + offset
        print("📍 New diagram position: \(position) (slot: \(nextSlot)) for file: \(filename)")
        print("🔢 Occupied slots: \(occupiedSlots.count) | Stored diagrams: \(filenameToSlot.count)")
        print("🔍 Surface detection status: running=\(surfaceDetector.isRunning), anchors=\(surfaceDetector.surfaceAnchors.count)")
        return position
    }
    
    /// Register a diagram with ID for tracking
    func registerDiagram(id: Int, filename: String, index: Int) {
        activeDiagrams[id] = index
        diagramFiles[id] = filename
        print("📝 Registered diagram: id=\(id), filename=\(filename), index=\(index)")
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
        print("🗑️ Removed diagram: id=\(id)")
    }
    
    /// Free up a position when diagram is removed
    func freeDiagramPosition(filename: String) {
        if let slot = filenameToSlot[filename] {
            occupiedSlots.remove(slot)
            filenameToSlot.removeValue(forKey: filename)
            print("🆓 Freed slot \(slot) for diagram: \(filename)")
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
        occupiedSlots.removeAll()
        filenameToSlot.removeAll()
        activeDiagrams.removeAll()
        diagramFiles.removeAll()
        print("🔄 Reset diagram positioning")
    }

    private func findNextAvailableSlot() -> GridSlot {
        var index = 0
        while true {
            let candidate = gridSlot(for: index)
            if candidate.z > 0 {
                index += 1
                continue // Skip slots that would place content behind the user
            }

            if !occupiedSlots.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }

    private func gridSlot(for index: Int) -> GridSlot {
        if index == 0 {
            return GridSlot(x: 0, z: 0)
        }

        var currentIndex = 0
        var stepSize = 1
        var x = 0
        var z = 0

        while true {
            for _ in 0..<stepSize {
                x += 1
                currentIndex += 1
                if currentIndex == index { return GridSlot(x: x, z: z) }
            }

            for _ in 0..<stepSize {
                z += 1
                currentIndex += 1
                if currentIndex == index { return GridSlot(x: x, z: z) }
            }

            stepSize += 1

            for _ in 0..<stepSize {
                x -= 1
                currentIndex += 1
                if currentIndex == index { return GridSlot(x: x, z: z) }
            }

            for _ in 0..<stepSize {
                z -= 1
                currentIndex += 1
                if currentIndex == index { return GridSlot(x: x, z: z) }
            }

            stepSize += 1
        }
    }

    /// Toggle plane visualization for debugging
    func togglePlaneVisualization() {
        showPlaneVisualization.toggle()
        surfaceDetector.setVisualizationVisible(showPlaneVisualization)
        print("🎨 Plane visualization: \(showPlaneVisualization ? "ON" : "OFF")")
    }
}
