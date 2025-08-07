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
    
    // Dynamic positioning for multiple diagrams
    private var nextDiagramIndex = 0
    private let diagramSpacing: Float = 3.0  // 3 meters between diagrams
    
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
    
    /// Get the next position for a new diagram, arranged in a horizontal line
    func getNextDiagramPosition() -> SIMD3<Float> {
        let basePosition = SIMD3<Float>(0, 1.0, -2.0)  // Constants.eyeLevel, Constants.frontOffset
        let offset = SIMD3<Float>(Float(nextDiagramIndex) * diagramSpacing, 0, 0)
        let position = basePosition + offset
        print("📍 New diagram position: \(position) (index: \(nextDiagramIndex))")
        print("🔍 Surface detection status: running=\(surfaceDetector.isRunning), anchors=\(surfaceDetector.surfaceAnchors.count)")
        nextDiagramIndex += 1
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
    
    /// Reset diagram positioning (when exiting immersive space)
    func resetDiagramPositioning() {
        nextDiagramIndex = 0
        activeDiagrams.removeAll()
        diagramFiles.removeAll()
        print("🔄 Reset diagram positioning")
    }
    
    /// Toggle plane visualization for debugging
    func togglePlaneVisualization() {
        showPlaneVisualization.toggle()
        surfaceDetector.setVisualizationVisible(showPlaneVisualization)
        print("🎨 Plane visualization: \(showPlaneVisualization ? "ON" : "OFF")")
    }
}