//
//  CollaborativeSessionModifier.swift
//  AVAR2
//
//  Created by Claude Code on 19-08-25.
//

import SwiftUI
import RealityKit
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "CollaborativeSessionModifier")

/// SwiftUI View Modifier for adding RealityKit Collaborative Sessions to RealityView
struct CollaborativeSessionModifier: ViewModifier {
    @State private var collaborativeManager = SimplifiedCollaborativeSessionManager()
    let onSessionChange: ((Bool) -> Void)?
    
    init(onSessionChange: ((Bool) -> Void)? = nil) {
        self.onSessionChange = onSessionChange
    }
    
    func body(content: Content) -> some View {
        content
            .environment(collaborativeManager)
            .onChange(of: collaborativeManager.isInCollaborativeSession) { _, isActive in
                onSessionChange?(isActive)
                logger.log("Collaborative session state changed: \(isActive)")
            }
            .onAppear {
                logger.log("CollaborativeSessionModifier attached to RealityView")
            }
    }
}

/// Environment key for accessing the collaborative session manager
struct CollaborativeSessionManagerKey: EnvironmentKey {
    static let defaultValue: SimplifiedCollaborativeSessionManager? = nil
}

extension EnvironmentValues {
    var collaborativeSessionManager: SimplifiedCollaborativeSessionManager? {
        get { self[CollaborativeSessionManagerKey.self] }
        set { self[CollaborativeSessionManagerKey.self] = newValue }
    }
}

/// Convenience extension for RealityView
extension View {
    /// Enables RealityKit Collaborative Sessions for this RealityView
    /// - Parameter onSessionChange: Optional callback when session state changes
    /// - Returns: Modified view with collaborative session support
    func enableCollaborativeSession(onSessionChange: ((Bool) -> Void)? = nil) -> some View {
        self.modifier(CollaborativeSessionModifier(onSessionChange: onSessionChange))
    }
}

/// Helper extension for making RealityKit entities collaborative
extension Entity {
    /// Makes this entity collaborative with automatic synchronization
    /// - Parameters:
    ///   - manager: The collaborative session manager
    ///   - identifier: Unique identifier for this entity across all participants
    func makeCollaborative(with manager: SimplifiedCollaborativeSessionManager, identifier: String) {
        manager.makeEntityCollaborative(self, identifier: identifier)
    }
    
    /// Removes collaborative behavior from this entity
    /// - Parameter manager: The collaborative session manager
    func removeFromCollaboration(with manager: SimplifiedCollaborativeSessionManager) {
        manager.removeEntityFromCollaboration(self)
    }
}