//
//  PlatformAppModel.swift
//  AVAR2
//
//  Created by Claude Code on 20-08-25.
//

import SwiftUI
import RealityKit

/// Cross-platform app model that handles both iOS and visionOS
@MainActor
@Observable
class AppModel: ObservableObject {
    #if os(visionOS)
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.open
    
    // visionOS ARKit surface detector
    let surfaceDetector = ARKitSurfaceDetector()
    private var surfaceDetectionStarted = false
    #endif
    
    #if os(iOS)
    // iOS ARKit manager
    private var arKitManager: iOSARKitManager?
    #endif
    
    // Common properties for both platforms
    var showPlaneVisualization = false
    var isInCollaborativeSession: Bool = false
    var collaborativeSessionParticipants: Int = 0
    
    // Dynamic positioning for multiple diagrams
    private let diagramSpacing: Float = 3.0  // 3 meters between diagrams
    private var usedPositions: Set<Int> = []  // Track which positions are occupied
    private var filenameToPosition: [String: Int] = [:] // Track filename to position mapping
    
    // Track active diagrams by ID for updates/redraw
    private var activeDiagrams: [Int: Int] = [:] // id -> diagram index
    private var diagramFiles: [Int: String] = [:] // id -> filename
    
    #if os(visionOS)
    func startSurfaceDetectionIfNeeded() async {
        guard !surfaceDetectionStarted else { 
            print("🚫 Surface detection already started - skipping")
            return 
        }
        print("🚀 Starting ONE-TIME surface detection for entire app session...")
        surfaceDetectionStarted = true
        await surfaceDetector.run()
    }
    #endif
    
    #if os(iOS)
    func setARKitManager(_ manager: iOSARKitManager) {
        self.arKitManager = manager
    }
    
    func startSurfaceDetectionIfNeeded() async {
        await arKitManager?.run()
    }
    #endif
    
    func togglePlaneVisualization() {
        showPlaneVisualization.toggle()
        print("🎨 Plane visualization toggled: \(showPlaneVisualization)")
        
        #if os(visionOS)
        surfaceDetector.setVisualizationVisible(showPlaneVisualization)
        #endif
        
        #if os(iOS)
        arKitManager?.setVisualizationVisible(showPlaneVisualization)
        #endif
    }
    
    // MARK: - Diagram Position Management
    
    func getNextDiagramPosition(for filename: String) -> SIMD3<Float> {
        // If this filename already has a position, return it
        if let existingIndex = filenameToPosition[filename] {
            return calculatePosition(for: existingIndex)
        }
        
        // Find next available position
        var nextIndex = 0
        while usedPositions.contains(nextIndex) {
            nextIndex += 1
        }
        
        usedPositions.insert(nextIndex)
        filenameToPosition[filename] = nextIndex
        
        let position = calculatePosition(for: nextIndex)
        print("📍 Assigned position \(nextIndex) to diagram '\(filename)': \(position)")
        return position
    }
    
    private func calculatePosition(for index: Int) -> SIMD3<Float> {
        // Arrange diagrams in a grid pattern
        let gridSize = 3 // 3x3 grid, then expand
        let row = index / gridSize
        let col = index % gridSize
        
        let baseX = Float(col - gridSize/2) * diagramSpacing
        let baseZ = Float(row) * diagramSpacing - 2.0 // Start 2m in front of user
        
        return SIMD3<Float>(baseX, 0.5, baseZ) // 0.5m above ground
    }
    
    func freeDiagramPosition(filename: String) {
        if let index = filenameToPosition[filename] {
            usedPositions.remove(index)
            filenameToPosition.removeValue(forKey: filename)
            print("🗑️ Freed position \(index) for diagram: \(filename)")
        }
    }
    
    func resetDiagramPositioning() {
        usedPositions.removeAll()
        filenameToPosition.removeAll()
        activeDiagrams.removeAll()
        diagramFiles.removeAll()
        print("🔄 Reset all diagram positioning")
    }
    
    // MARK: - Diagram ID Tracking (for HTTP updates)
    
    func registerDiagram(id: Int, filename: String, index: Int) {
        activeDiagrams[id] = index
        diagramFiles[id] = filename
        print("📝 Registered diagram ID \(id) -> \(filename) at index \(index)")
    }
    
    func getDiagramInfo(for id: Int) -> (filename: String, index: Int)? {
        guard let index = activeDiagrams[id],
              let filename = diagramFiles[id] else {
            return nil
        }
        return (filename: filename, index: index)
    }
    
    func clearAllDiagrams() {
        resetDiagramPositioning()
        print("🗑️ Cleared all diagrams")
    }
    
    // MARK: - Collaborative Session Management
    
    func updateCollaborativeSession(isActive: Bool, participantCount: Int) {
        isInCollaborativeSession = isActive
        collaborativeSessionParticipants = participantCount
        print("🤝 Collaborative session updated: active=\(isActive), participants=\(participantCount)")
    }
}

// MARK: - Platform-specific extensions

#if os(iOS)
extension AppModel {
    func getSurfaceAnchors() -> [Any] {
        return arKitManager?.surfaceAnchors ?? []
    }
    
    func isARReady() -> Bool {
        return arKitManager?.isTrackingReady ?? false
    }
    
    func getErrorMessage() -> String? {
        return arKitManager?.errorMessage
    }
}
#endif

#if os(visionOS)
extension AppModel {
    func getSurfaceAnchors() -> [Any] {
        return surfaceDetector.surfaceAnchors
    }
    
    func isARReady() -> Bool {
        return surfaceDetector.isRunning
    }
    
    func getErrorMessage() -> String? {
        return surfaceDetector.errorMessage
    }
}
#endif