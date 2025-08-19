//
//  DiagramSyncService.swift
//  AVAR2
//
//  Created by Claude Code on 19-08-25.
//

import Foundation
import RealityKit
import GroupActivities
import Combine
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "DiagramSyncService")

/// Handles synchronization of diagram data across collaborative sessions
@MainActor
@Observable
class DiagramSyncService {
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    
    /// Callback for when diagram data is received from other participants
    var onDiagramReceived: ((DiagramData) -> Void)?
    
    /// Callback for when diagram position is updated by other participants
    var onDiagramPositionUpdated: ((String, SIMD3<Float>) -> Void)?
    
    /// Initialize with a collaborative session
    func configure(with session: GroupSession<DiagramActivity>) {
        messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        
        setupMessageHandlers()
        logger.log("DiagramSyncService configured for session with \(session.activeParticipants.count) participants")
    }
    
    /// Send diagram data to all participants
    func sendDiagram(_ diagramData: DiagramData) {
        guard let messenger = messenger else {
            logger.warning("Cannot send diagram - no messenger available")
            return
        }
        
        Task {
            do {
                try await messenger.send(DiagramMessage.diagramData(diagramData))
                logger.log("Sent diagram data to participants: \(diagramData.filename)")
            } catch {
                logger.error("Failed to send diagram data: \(error.localizedDescription)")
            }
        }
    }
    
    /// Send diagram position update to all participants
    func sendDiagramPosition(_ filename: String, position: SIMD3<Float>) {
        guard let messenger = messenger else {
            logger.warning("Cannot send diagram position - no messenger available")
            return
        }
        
        let positionUpdate = DiagramPositionUpdate(filename: filename, position: position)
        
        Task {
            do {
                try await messenger.send(DiagramMessage.positionUpdate(positionUpdate))
                logger.log("Sent diagram position update: \(filename) -> \(position)")
            } catch {
                logger.error("Failed to send diagram position: \(error.localizedDescription)")
            }
        }
    }
    
    /// Send immersion level update to all participants
    func sendImmersionLevel(_ level: Double) {
        guard let messenger = messenger else {
            logger.warning("Cannot send immersion level - no messenger available")
            return
        }
        
        Task {
            do {
                try await messenger.send(DiagramMessage.immersionLevel(level))
                logger.log("Sent immersion level update: \(level)")
            } catch {
                logger.error("Failed to send immersion level: \(error.localizedDescription)")
            }
        }
    }
    
    /// Callback for immersion level updates from other participants
    var onImmersionLevelReceived: ((Double) -> Void)?
    
    private func setupMessageHandlers() {
        guard let messenger = messenger else { return }
        
        Task {
            for await (message, context) in messenger.messages(of: DiagramMessage.self) {
                await handleMessage(message)
            }
        }
    }
    
    private func handleMessage(_ message: DiagramMessage) {
        switch message {
        case .diagramData(let diagramData):
            logger.log("Received diagram data: \(diagramData.filename)")
            onDiagramReceived?(diagramData)
            
        case .positionUpdate(let positionUpdate):
            logger.log("Received diagram position update: \(positionUpdate.filename) -> \(positionUpdate.position.simd)")
            onDiagramPositionUpdated?(positionUpdate.filename, positionUpdate.position.simd)
            
        case .immersionLevel(let level):
            logger.log("Received immersion level update: \(level)")
            onImmersionLevelReceived?(level)
        }
    }
    
    /// Clean up resources
    func disconnect() {
        subscriptions.removeAll()
        messenger = nil
        logger.log("DiagramSyncService disconnected")
    }
}

/// Messages that can be sent between participants
enum DiagramMessage: Codable {
    case diagramData(DiagramData)
    case positionUpdate(DiagramPositionUpdate)
    case immersionLevel(Double)
}

/// Diagram data that can be synchronized across participants
struct DiagramData: Codable, Identifiable {
    let id: String
    let filename: String
    let jsonData: String
    let position: DiagramPosition
    let timestamp: Date
    
    init(filename: String, jsonData: String, position: SIMD3<Float>) {
        self.id = UUID().uuidString
        self.filename = filename
        self.jsonData = jsonData
        self.position = DiagramPosition(position)
        self.timestamp = Date()
    }
}

/// Position update for existing diagrams
struct DiagramPositionUpdate: Codable {
    let filename: String
    let position: DiagramPosition
    let timestamp: Date
    
    init(filename: String, position: SIMD3<Float>) {
        self.filename = filename
        self.position = DiagramPosition(position)
        self.timestamp = Date()
    }
}

/// Codable wrapper for SIMD3<Float>
struct DiagramPosition: Codable {
    let x: Float
    let y: Float
    let z: Float
    
    init(_ position: SIMD3<Float>) {
        self.x = position.x
        self.y = position.y
        self.z = position.z
    }
    
    var simd: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}