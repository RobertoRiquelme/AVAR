//
//  CollaborativeSessionView.swift
//  AVAR2
//
//  Created by Claude Code on 19-08-25.
//

import SwiftUI

struct CollaborativeSessionView: View {
    let collaborativeManager: SimplifiedCollaborativeSessionManager
    let showToast: (String, String, Color) -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Header with status indicator
            HStack {
                Image(systemName: collaborativeManager.isInCollaborativeSession ? "person.2.fill" : "person.2")
                    .foregroundColor(.purple)
                    .font(.title3)
                
                Text("Collaboration")
                    .font(.headline)
                    .foregroundColor(.purple)
                
                Spacer()
                
                // Status indicator
                Circle()
                    .fill(collaborativeManager.isInCollaborativeSession ? .green : .gray)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: 2)
                    )
            }
            
            // Status information
            statusSection
            
            // Action buttons
            actionButtons
            
            // Connection instructions (only when not connected)
            if !collaborativeManager.isInCollaborativeSession {
                Text("💡 Other AVAR2 users will automatically see and can join your session")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            collaborativeManager.isInCollaborativeSession ? 
                            Color.green.opacity(0.5) : Color.purple.opacity(0.3),
                            lineWidth: collaborativeManager.isInCollaborativeSession ? 2 : 1
                        )
                )
        )
    }
    
    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 4) {
                    Text(collaborativeManager.sessionState)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(statusColor)
                    
                    // Show loading indicator when starting
                    if isStartingCollaboration {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
            }
            
            if collaborativeManager.isInCollaborativeSession {
                connectedStatusView
            } else {
                disconnectedStatusView
            }
        }
    }
    
    @ViewBuilder
    private var connectedStatusView: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .foregroundColor(.blue)
                .font(.caption)
            
            Text("\(collaborativeManager.sessionParticipantCount) participant\(collaborativeManager.sessionParticipantCount == 1 ? "" : "s") connected")
                .font(.subheadline)
                .foregroundColor(.blue)
            
            Spacer()
            
            // Activity indicator
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(.blue)
                        .frame(width: 4, height: 4)
                        .scaleEffect(collaborativeManager.isInCollaborativeSession ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                            value: collaborativeManager.isInCollaborativeSession
                        )
                }
            }
        }
        
        // Features and activity
        activeFeatures
    }
    
    @ViewBuilder
    private var disconnectedStatusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start collaboration to enable:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                featureItem("Real-time diagram sharing")
                featureItem("Synchronized positioning") 
                featureItem("Multi-user immersive experience")
            }
        }
    }
    
    @ViewBuilder
    private func featureItem(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var activeFeatures: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Features:")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Label("Diagram Sharing", systemImage: "square.3.layers.3d")
                    .font(.caption2)
                    .foregroundColor(.green)
                
                Label("Position Sync", systemImage: "move.3d")
                    .font(.caption2)
                    .foregroundColor(.green)
                
                Label("Immersion Sync", systemImage: "eye.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
            
            // Activity statistics
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.blue)
                                .font(.caption2)
                            Text("\(collaborativeManager.diagramsSent)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                        
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                            Text("\(collaborativeManager.diagramsReceived)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last Activity")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Text(collaborativeManager.getLastActivityString())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.top, 4)
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if collaborativeManager.isInCollaborativeSession {
                Button(action: {
                    collaborativeManager.endCollaboration()
                    showToast(
                        "Collaborative session ended",
                        "xmark.circle.fill",
                        .orange
                    )
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("End Session")
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                
                Button(action: {
                    // Refresh session status
                    print("🔄 Refreshing collaboration status...")
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.blue)
                
            } else {
                Button(action: {
                    // Show immediate toast feedback
                    showToast(
                        "Starting collaborative session...",
                        "play.circle.fill",
                        .blue
                    )
                    
                    Task {
                        print("🚀 User tapped Start Collaboration button")
                        print("🔍 Current session state: \(collaborativeManager.sessionState)")
                        await collaborativeManager.startCollaboration()
                        print("🔍 Session state after startCollaboration: \(collaborativeManager.sessionState)")
                    }
                }) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Start Collaboration")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var isStartingCollaboration: Bool {
        collaborativeManager.sessionState.contains("Starting") || 
        collaborativeManager.sessionState.contains("Waiting")
    }
    
    private var statusColor: Color {
        if collaborativeManager.isInCollaborativeSession {
            return .green
        } else if isStartingCollaboration {
            return .blue
        } else if collaborativeManager.sessionState.contains("Failed") {
            return .red
        } else {
            return .orange
        }
    }
}