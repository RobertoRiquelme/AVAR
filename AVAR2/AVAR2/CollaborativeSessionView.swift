import SwiftUI

struct CollaborativeSessionView: View {
    @ObservedObject var sessionManager: CollaborativeSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(instructions)

                    if sessionManager.companionMode == .idle {
                        Button {
                            sessionManager.startCompanionConnection()
                        } label: {
                            Label(startLabel, systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        connectionStatus
                        Button(sessionManager.connectedPeers.isEmpty ? "Stop" : "Disconnect Companion") {
                            sessionManager.stopCompanionConnection()
                        }
                        .buttonStyle(.bordered)
                    }

                    if let error = sessionManager.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        if error.contains("Network permission") {
                            Text("Enable AVAR2 in Settings → Privacy & Security → Local Network, then try again.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("The iPhone receives diagrams. Use SharePlay on Vision Pro for diagrams aligned in the same room.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("iPhone Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var instructions: String {
        #if os(visionOS)
        return "Allow an iPhone on the local network to connect. On the iPhone, open AVAR2 → Controls → Connect to Vision Pro, then tap Find Vision Pro."
        #else
        return "On Vision Pro, open Collaboration → iPhone Companion and tap Allow iPhone to Connect. Then find and select your Vision Pro here."
        #endif
    }

    private var startLabel: String {
        #if os(visionOS)
        return "Allow iPhone to Connect"
        #else
        return "Find Vision Pro"
        #endif
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if let peer = sessionManager.connectingCompanion {
            ProgressView("Connecting to \(peer.displayName)…")
        } else if sessionManager.connectedPeers.isEmpty {
            Label(
                sessionManager.companionMode == .advertising ? "Waiting for iPhone…" : "Looking for Vision Pro…",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            ForEach(sessionManager.availablePeers, id: \.self) { peer in
                Button("Connect to \(peer.displayName)") {
                    sessionManager.connectToPeer(peer)
                }
                .buttonStyle(.bordered)
            }
        } else {
            ForEach(sessionManager.connectedPeers, id: \.self) { peer in
                Label("Connected to \(peer.displayName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    CollaborativeSessionView(sessionManager: CollaborativeSessionManager())
}
