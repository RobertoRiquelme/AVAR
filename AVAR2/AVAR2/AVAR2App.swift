//
//  AVAR2App.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import QuartzCore
import RealityKit
import RealityKitContent
import Foundation

// NOTE: Removed Notification.Name extensions for custom immersion messaging;
// the system controls immersion via the Digital Crown in .progressive style.

/// Separate view for HTTP Server tab to reduce complexity
struct HTTPServerTabView: View {
    @ObservedObject var httpServer: HTTPServer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HTTP Server Controls")
                .font(.headline)
                .padding(.horizontal)
            
            HStack {
                Button(httpServer.isRunning ? "Stop Server" : "Start Server") {
                    if httpServer.isRunning {
                        httpServer.stop()
                    } else {
                        httpServer.start()
                    }
                }
                .font(.title3)
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            .padding(.horizontal)
            
            ServerStatusView(httpServer: httpServer)
            ServerLogsView(httpServer: httpServer)
        }
    }
}

/// Server status section
struct ServerStatusView: View {
    @ObservedObject var httpServer: HTTPServer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Status:")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal)
            
            Text(httpServer.serverStatus)
                .font(.body)
                .foregroundColor(httpServer.isRunning ? .green : .secondary)
                .padding(.horizontal)
            
            if httpServer.isRunning {
                Text("URL: \(httpServer.serverURL)")
                    .font(.body)
                    .foregroundColor(.blue)
                    .padding(.horizontal)
            }
        }
    }
}

/// Server logs section
struct ServerLogsView: View {
    @ObservedObject var httpServer: HTTPServer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Logs:")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.horizontal)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if httpServer.serverLogs.isEmpty {
                            Text("No logs yet")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(8)
                        } else {
                            ForEach(Array(httpServer.serverLogs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .id(index)
                            }
                        }
                    }
                    .padding(4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                .frame(height: 120)
                .onChange(of: httpServer.serverLogs.count) { _, _ in
                    if !httpServer.serverLogs.isEmpty {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(httpServer.serverLogs.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            // Last received JSON in a collapsible section
            if !httpServer.lastReceivedJSON.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Received JSON:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal)
                    
                    ScrollView {
                        Text(httpServer.lastReceivedJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .frame(height: 60)
                    .padding(.horizontal)
                }
            }
        }
    }
}

#if os(visionOS)
/// Static surface detection view that never changes
struct StaticSurfaceView: View {
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        RealityView { content in
            content.add(appModel.surfaceDetector.rootEntity)
        }
    }
}

/// Wrapper for the entire immersive space (Digital Crown controls progressive immersion)
struct ImmersiveSpaceWrapper: View {
    let activeFiles: [String]
    let onClose: (String) -> Void
    let onAppearAction: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var showDebugInfo: Bool = false
  
    var collaborativeSession: CollaborativeSessionManager? = nil
    var showBackgroundOverlay: Bool = false
    
    var body: some View {
        ZStack {
          
            // No inside-out sphere or manual opacity — visionOS handles blending in .progressive.
              ImmersiveContentView(
                  activeFiles: activeFiles,
                  onClose: onClose,
                  showDebugInfo: $showDebugInfo
              )
              .environment(appModel)
            // Optional app-owned background overlay; leave disabled to let system Environments show
            if showBackgroundOverlay {
                RealityView { content in
                    let backgroundEntity = Entity()
                    let mesh = MeshResource.generateSphere(radius: 1000)
                    var material = PhysicallyBasedMaterial()
                    let alphaValue = Float(max(0.0, immersionLevel * 1.5))
                    material.baseColor = .init(tint: .black.withAlphaComponent(CGFloat(alphaValue)), texture: nil)
                    material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(floatLiteral: alphaValue))
                    backgroundEntity.components.set(ModelComponent(mesh: mesh, materials: [material]))
                    backgroundEntity.position = [0, 0, 0]
                    backgroundEntity.scale = SIMD3<Float>(-1, 1, 1)
                    backgroundEntity.name = "immersiveBackgroundSphere"
                    content.add(backgroundEntity)
                } update: { content in
                    guard abs(immersionLevel - lastUpdateLevel) > 0.001 else { return }
                    if let bg = content.entities.first(where: { $0.name == "immersiveBackgroundSphere" }),
                       var modelComponent = bg.components[ModelComponent.self] {
                        var material = PhysicallyBasedMaterial()
                        let alphaValue = Float(max(0.0, immersionLevel * 1.2))
                        material.baseColor = .init(tint: .black.withAlphaComponent(CGFloat(alphaValue)), texture: nil)
                        material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(floatLiteral: alphaValue))
                        modelComponent.materials = [material]
                        bg.components.set(modelComponent)
                        lastUpdateLevel = immersionLevel
                    }
                }
            }
            
            // The actual content (diagrams, surface detection)
            ImmersiveContentView(activeFiles: activeFiles, onClose: onClose, immersionLevel: $immersionLevel, showDebugInfo: $showDebugInfo, collaborativeSession: collaborativeSession)
                .environment(appModel)
            
            // Immersion level indicator - positioned in 3D world space
            RealityView { content in
                // This creates a persistent anchor for the UI text
            } update: { content in
                // Remove existing indicator
                content.entities.removeAll { $0.name == "immersionIndicator" }
                
                // Create new indicator positioned in world space
                let indicatorEntity = Entity()
                indicatorEntity.name = "immersionIndicator"
                indicatorEntity.position = [-1.5, 1.2, -2] // Top-left of user's field of view
                
                // For now, just use a simple sphere as placeholder (in real app, you'd use text)
                let mesh = MeshResource.generateSphere(radius: 0.05)
                var material = UnlitMaterial(color: .white)
                material.color = .init(tint: .white.withAlphaComponent(0.8))
                indicatorEntity.components.set(ModelComponent(mesh: mesh, materials: [material]))
                
                content.add(indicatorEntity)
            }
        }
        .focusable(true)
        .onAppear(perform: onAppearAction)
        .onKeyPress(.space) {
            showDebugInfo.toggle()
            print("🐛 Debug info toggled: \(showDebugInfo)")
            return .handled
        }
    }
}

/// Immersive content view; no manual immersion value — blend is controlled by the system
struct ImmersiveContentView: View {
    let activeFiles: [String]
    let onClose: (String) -> Void
    @Binding var showDebugInfo: Bool
    @Environment(AppModel.self) private var appModel
    var collaborativeSession: CollaborativeSessionManager? = nil
    
    var body: some View {
        ZStack {
            // Static surface detection layer (only when explicitly visible)
            if appModel.showPlaneVisualization {
                StaticSurfaceView().environment(appModel)
                }
            
            // Dynamic diagrams layer
            Group {
                ForEach(activeFiles, id: \.self) { file in
                    ContentView(filename: file, onClose: {
                        onClose(file)
                    }, collaborativeSession: collaborativeSession)
                }
            }
            .environment(appModel)
        }
        // Removed: DragGesture that “simulated” the Crown and any opacity math
    }
}

final class FPSMonitor: ObservableObject {
    @Published private(set) var fps: Int = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameCount: Int = 0
    
    init() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    @objc private func tick() {
        guard let link = displayLink else { return }
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            frameCount = 0
            return
        }
        frameCount += 1
        let delta = link.timestamp - lastTimestamp
        if delta >= 1.0 {
            fps = Int(round(Double(frameCount) / delta))
            frameCount = 0
            lastTimestamp = link.timestamp
        }
    }
}

/// Isolated FPS display view to prevent picker reloads
struct FPSDisplayView: View {
    @StateObject private var fpsMonitor = FPSMonitor()
    
    var body: some View {
        Text("\(fpsMonitor.fps) FPS")
            .font(.title)
    }
}
#endif
