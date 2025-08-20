//
//  SimplifiedCollaborativeSessionManager.swift
//  AVAR2
//
//  Created by Claude Code on 19-08-25.
//

import Foundation
import RealityKit
import GroupActivities
import Combine
import SwiftUI
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "SimplifiedCollaborativeSessionManager")

/// Simplified collaborative session manager that focuses on data sharing without RealityKit sync issues
@MainActor
@Observable 
class SimplifiedCollaborativeSessionManager {
    /// Current collaboration session
    private var groupSession: GroupSession<DiagramActivity>?
    
    /// Diagram data synchronization service
    private var diagramSyncService = DiagramSyncService()
    
    /// Subscribers for session management
    private var subscriptions = Set<AnyCancellable>()
    
    /// Published state for UI
    var isInCollaborativeSession: Bool = false
    var sessionParticipantCount: Int = 0
    var sessionState: String = "Not Connected"
    
    /// Additional status information
    var lastActivityTime: Date? = nil
    var diagramsSent: Int = 0
    var diagramsReceived: Int = 0
    var connectionQuality: String = "Unknown"
    
    /// Callback for when diagram data is received from other participants
    var onDiagramReceived: ((DiagramData) -> Void)? {
        get { diagramSyncService.onDiagramReceived }
        set { diagramSyncService.onDiagramReceived = newValue }
    }
    
    /// Callback for when diagram positions are updated by other participants
    var onDiagramPositionUpdated: ((String, SIMD3<Float>) -> Void)? {
        get { diagramSyncService.onDiagramPositionUpdated }
        set { diagramSyncService.onDiagramPositionUpdated = newValue }
    }
    
    /// Callback for when immersion level is updated by other participants
    var onImmersionLevelReceived: ((Double) -> Void)? {
        get { diagramSyncService.onImmersionLevelReceived }
        set { diagramSyncService.onImmersionLevelReceived = newValue }
    }
    
    /// Initialize collaborative session manager
    init() {
        setupActivityObserver()
        setupDiagramCallbacks()
        
        #if DEBUG
        // Add debug menu simulation - uncomment to test UI states
        // simulateCollaborativeStates()
        #endif
    }
    
    /// Setup callbacks to track diagram activity
    private func setupDiagramCallbacks() {
        onDiagramReceived = { [weak self] diagramData in
            Task { @MainActor in
                self?.lastActivityTime = Date()
                self?.diagramsReceived += 1
                logger.log("📥 Received diagram from participant: \(diagramData.filename) (total received: \(self?.diagramsReceived ?? 0))")
            }
        }
    }
    
    /// Start a new collaborative session
    func startCollaboration() async {
        logger.log("Starting collaborative session...")
        
        // Provide immediate UI feedback
        sessionState = "Starting collaboration..."
        
        let activity = DiagramActivity()
        
        do {
            _ = try await activity.activate()
            logger.log("Collaborative activity activated successfully")
            
            // Update UI to show waiting for participants
            sessionState = "Waiting for participants..."
            
        } catch {
            logger.error("Failed to activate collaborative activity: \(error.localizedDescription)")
            
            // Update UI to show error state
            sessionState = "Failed to start - \(error.localizedDescription)"
            
            // Reset to not connected after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                Task { @MainActor in
                    self.sessionState = "Not Connected"
                }
            }
        }
    }
    
    /// End the current collaborative session
    func endCollaboration() {
        logger.log("Ending collaborative session...")
        
        diagramSyncService.disconnect()
        groupSession?.leave()
        groupSession = nil
        
        isInCollaborativeSession = false
        sessionParticipantCount = 0
        sessionState = "Not Connected"
        
        // Reset activity tracking
        resetActivityCounters()
        
        subscriptions.removeAll()
    }
    
    /// Reset activity tracking counters
    func resetActivityCounters() {
        self.lastActivityTime = nil
        self.diagramsSent = 0
        self.diagramsReceived = 0
        self.connectionQuality = "Unknown"
        logger.log("🔄 Reset activity counters")
    }
    
    /// Get formatted last activity time
    func getLastActivityString() -> String {
        guard let lastActivityTime = self.lastActivityTime else {
            return "No recent activity"
        }
        
        let interval = Date().timeIntervalSince(lastActivityTime)
        if interval < 60 {
            return "Active now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }
    
    /// Setup observer for incoming collaborative activities
    private func setupActivityObserver() {
        Task {
            for await session in DiagramActivity.sessions() {
                await configureGroupSession(session)
            }
        }
    }
    
    /// Configure a new group session
    private func configureGroupSession(_ session: GroupSession<DiagramActivity>) async {
        logger.log("Configuring group session with \(session.activeParticipants.count) participants")
        
        groupSession = session
        
        // Setup diagram data synchronization
        diagramSyncService.configure(with: session)
        
        // Update UI state
        isInCollaborativeSession = true
        sessionParticipantCount = session.activeParticipants.count
        sessionState = "Connected (\(session.activeParticipants.count) participants)"
        
        // Observe participant changes
        let participantsSubscription: AnyCancellable = session.$activeParticipants
            .sink { [weak self] (participants: Set<Participant>) in
                Task { @MainActor in
                    self?.sessionParticipantCount = participants.count
                    self?.sessionState = "Connected (\(participants.count) participants)"
                    logger.log("Session participants updated: \(participants.count)")
                }
            }
        subscriptions.insert(participantsSubscription)
        
        // Note: State observation temporarily disabled due to type inference issues
        // Will be re-enabled when API stabilizes
        logger.log("Session configured and ready to join")
        
        // Join the session
        session.join()
    }
    
    /// Send diagram data to all participants
    func sendDiagram(_ filename: String, jsonData: String, position: SIMD3<Float>) {
        let diagramData = DiagramData(filename: filename, jsonData: jsonData, position: position)
        diagramSyncService.sendDiagram(diagramData)
        
        // Update activity tracking
        self.lastActivityTime = Date()
        self.diagramsSent += 1
        logger.log("📤 Sent diagram to participants: \(filename) (total sent: \(self.diagramsSent))")
    }
    
    /// Send diagram position update to all participants
    func sendDiagramPosition(_ filename: String, position: SIMD3<Float>) {
        diagramSyncService.sendDiagramPosition(filename, position: position)
        self.lastActivityTime = Date()
        logger.log("📍 Sent position update for: \(filename)")
    }
    
    /// Send immersion level update to all participants
    func sendImmersionLevel(_ level: Double) {
        diagramSyncService.sendImmersionLevel(level)
        self.lastActivityTime = Date()
        logger.log("🎛️ Sent immersion level update: \(String(format: "%.0f%%", level * 100))")
    }
    
    /// Simplified entity collaborative marking (just sets name for identification)
    func makeEntityCollaborative(_ entity: Entity, identifier: String) {
        entity.name = identifier
        logger.log("Made entity collaborative with identifier: \(identifier)")
    }
    
    /// Remove collaborative behavior from an entity
    func removeEntityFromCollaboration(_ entity: Entity) {
        entity.name = ""
        logger.log("Removed entity from collaboration")
    }
    
    #if DEBUG
    /// Simulate collaborative states for testing UI without real devices
    private func simulateCollaborativeStates() {
        // Simulate different states with delays
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.sessionState = "Simulated: Starting..."
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            self.sessionState = "Simulated: Waiting for participants..."
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            self.isInCollaborativeSession = true
            self.sessionParticipantCount = 2
            self.sessionState = "Simulated: Connected (2 participants)"
            self.lastActivityTime = Date()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            self.diagramsReceived = 3
            self.diagramsSent = 1
        }
    }
    
    /// Enable debug mode - call this from UI for testing
    func enableDebugMode() {
        logger.log("🐛 Debug mode enabled - simulating collaborative states")
        simulateCollaborativeStates()
    }
    #endif
}

/// Group Activity for diagram collaboration
struct DiagramActivity: GroupActivity {
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "AVAR2 Diagram Collaboration"
        metadata.subtitle = "Share and collaborate on 3D diagrams"
        metadata.previewImage = nil
        metadata.type = .generic
        return metadata
    }
}