import SwiftUI

struct CollaborativeSessionView: View {
    @ObservedObject var sessionManager: CollaborativeSessionManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Session Status
                statusSection
                
                // Controls
                controlsSection
                
                // Error display
                if let error = sessionManager.lastError {
                    errorSection(error: error)
                }
                
                // Available Peers (for manual connection)
                if sessionManager.isSessionActive && !sessionManager.isHost {
                    availablePeersSection
                }
                
                // Connected Peers
                if !sessionManager.connectedPeers.isEmpty {
                    peersSection
                }
                
                // Shared Diagrams
                if !sessionManager.sharedDiagrams.isEmpty {
                    sharedDiagramsSection
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Collaborative Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var statusSection: some View {
        VStack(spacing: 8) {
            Image(systemName: sessionManager.isSessionActive ? "wifi" : "wifi.slash")
                .font(.system(size: 40))
                .foregroundColor(sessionManager.isSessionActive ? .green : .gray)

            Text(sessionManager.sessionState)
                .font(.headline)
                .multilineTextAlignment(.center)

            if sessionManager.isHost {
                Text("You are hosting")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(8)
            }

            // Shared anchor status indicator
            if sessionManager.isSessionActive {
                if let anchor = sessionManager.sharedAnchor {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle.fill")
                            .foregroundColor(.green)
                        Text("Anchor: \(anchor.id.prefix(6))...")
                            .font(.caption2)
                        Text("conf: \(String(format: "%.0f%%", anchor.confidence * 100))")
                            .font(.caption2)
                            .foregroundColor(anchor.confidence > 0.8 ? .green : .orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "link.circle")
                        .foregroundColor(.orange)
                        Text("No shared anchor - positions may misalign")
                        .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }

#if os(visionOS)
            if #available(visionOS 26.0, *) {
                if sessionManager.isSharePlayActive {
                    HStack(spacing: 6) {
                        Image(systemName: sessionManager.sharedAnchorUsesSharedWorld ? "checkmark.seal.fill" : "link")
                            .foregroundColor(sessionManager.sharedAnchorUsesSharedWorld ? .green : .secondary)
                        Text(sessionManager.sharedAnchorUsesSharedWorld ? "Shared world anchor ready" : "Shared world anchor not created")
                            .font(.caption2)
                            .foregroundColor(sessionManager.sharedAnchorUsesSharedWorld ? .green : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
            }
#endif

#if canImport(GroupActivities)
            if sessionManager.isSharePlayActive {
                Label("SharePlay active", systemImage: "person.3.sequence")
                    .font(.caption)
                    .foregroundColor(.purple)
            }
#endif
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
    
    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Connection Issue")
                    .font(.headline)
                    .foregroundColor(.orange)
            }
            
            Text(error)
                .font(.body)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            
            if error.contains("Network permission") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To fix this:")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("1. Go to Settings → Privacy & Security → Local Network")
                        .font(.caption2)
                    Text("2. Enable Local Network access for AVAR2")
                        .font(.caption2)
                    Text("3. Restart the app")
                        .font(.caption2)
                }
                .padding(.top, 4)
                .foregroundColor(.secondary)
            }
            
            Button("Dismiss") {
                sessionManager.lastError = nil
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var controlsSection: some View {
        VStack(spacing: 12) {
            if !sessionManager.isSessionActive {
                Button("Host Session") {
                    Task {
                        await sessionManager.startHosting()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("Join Session") {
                    Task {
                        await sessionManager.joinSession()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            } else {
                // Anchor broadcast button - important for proper alignment
                if sessionManager.isHost {
                    #if os(visionOS)
                    Button(action: {
                        sessionManager.broadcastCurrentSharedAnchor()
                    }) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(sessionManager.sharedAnchor == nil ? "Broadcast Anchor (Required)" : "Update Anchor")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sessionManager.sharedAnchor == nil ? .orange : .blue)
                    .frame(maxWidth: .infinity)
                    #endif
                }

#if os(visionOS)
                if #available(visionOS 26.0, *) {
                    if sessionManager.isSharePlayActive && sessionManager.isHost {
                        Button("Create Shared Anchor") {
                            Task {
                                await sessionManager.ensureSharedWorldAnchorInFrontOfUser()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!sessionManager.worldAnchorSharingAvailable
                                  || sessionManager.sharedAnchorUsesSharedWorld)
                        .frame(maxWidth: .infinity)
                    }
                }
#endif

                Button("Stop Session") {
                    sessionManager.stopSession()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
            }

            #if canImport(GroupActivities)
            if sessionManager.isSharePlayActive {
                Button("Stop SharePlay") {
                    sessionManager.stopSharePlay()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)
            } else {
                Button("Start SharePlay") {
                    Task {
                        await sessionManager.startSharePlay()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .frame(maxWidth: .infinity)
            }
            #endif
        }
    }
    
    private var availablePeersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Hosts (\(sessionManager.availablePeers.count))")
                .font(.headline)
            
            if sessionManager.availablePeers.isEmpty {
                VStack {
                    Text("Searching for hosts...")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("Auto-connect enabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                ForEach(sessionManager.availablePeers, id: \.self) { peer in
                    HStack {
                        Image(systemName: "person.circle")
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if !sessionManager.connectedPeers.contains(peer) {
                            Button("Connect") {
                                sessionManager.connectToPeer(peer)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Text("Connected")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected Devices (\(sessionManager.connectedPeers.count))")
                .font(.headline)
            
            ForEach(sessionManager.connectedPeers, id: \.self) { peer in
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundColor(.green)
                    Text(peer.displayName)
                        .font(.body)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
    
    private var sharedDiagramsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shared Diagrams (\(sessionManager.sharedDiagrams.count))")
                .font(.headline)
            
            ForEach(sessionManager.sharedDiagrams) { diagram in
                HStack {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diagram.filename)
                            .font(.body)
                            .fontWeight(.medium)
                        Text("\(diagram.elements.count) elements")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(diagram.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

#Preview {
    CollaborativeSessionView(sessionManager: CollaborativeSessionManager())
}
