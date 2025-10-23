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
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    static let setImmersionLevel = Notification.Name("setImmersionLevel")
}

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
    @State private var didCopyJSON = false
    
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
                    HStack(spacing: 8) {
                        Text("Last Received JSON:")
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Button {
                            copyJSONToClipboard(httpServer.lastReceivedJSON)
                        } label: {
                            Label(didCopyJSON ? "Copied" : "Copy", systemImage: didCopyJSON ? "checkmark" : "doc.on.doc")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .font(.caption2)
                    }
                    .padding(.horizontal)
                    
                    ScrollView {
                        Text(httpServer.lastReceivedJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(6)
                            .textSelection(.enabled)
                    }
                    .frame(height: 60)
                    .padding(.horizontal)
                    
                    if didCopyJSON {
                        Text("Copied to clipboard")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
}

private extension ServerLogsView {
    func copyJSONToClipboard(_ json: String) {
        guard !json.isEmpty else { return }
#if canImport(UIKit)
        UIPasteboard.general.string = json
#endif
        didCopyJSON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            didCopyJSON = false
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

/// Wrapper for the entire immersive space with proper background positioning
struct ImmersiveSpaceWrapper: View {
    @Binding var activeFiles: [String]
    let onClose: (String) -> Void
    @Environment(AppModel.self) private var appModel
    var collaborativeSession: CollaborativeSessionManager? = nil
    @State private var immersionLevel: Double = 0.25
    @State private var showDebugInfo: Bool = false
    @State private var lastUpdateLevel: Double = -1.0 // Track last updated level
    var showBackgroundOverlay: Bool = false
    
    var body: some View {
        ZStack {
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
            ImmersiveContentView(activeFiles: $activeFiles, onClose: onClose, immersionLevel: $immersionLevel, showDebugInfo: $showDebugInfo, collaborativeSession: collaborativeSession)
                .environment(appModel)
            
        }
        .focusable(true)
        .onKeyPress(.space) {
            showDebugInfo.toggle()
            print("🐛 Debug info toggled: \(showDebugInfo)")
            return .handled
        }
        .onKeyPress("r") {
            withAnimation(.easeInOut(duration: 0.5)) {
                immersionLevel = 0.0
            }
            print("🔄 Immersion level reset to 0")
            return .handled
        }
        .onKeyPress("f") {
            withAnimation(.easeInOut(duration: 0.5)) {
                immersionLevel = 1.0
            }
            print("🌑 Full immersion activated")
            return .handled
        }
        .onKeyPress(.upArrow) {
            withAnimation(.easeInOut(duration: 0.2)) {
                immersionLevel = min(1.0, immersionLevel + 0.1)
            }
            print("⬆️ Immersion increased to \(String(format: "%.2f", immersionLevel))")
            return .handled
        }
        .onKeyPress(.downArrow) {
            withAnimation(.easeInOut(duration: 0.2)) {
                immersionLevel = max(0.0, immersionLevel - 0.1)
            }
            print("⬇️ Immersion decreased to \(String(format: "%.2f", immersionLevel))")
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .setImmersionLevel)) { notification in
            print("📡 Notification received in ImmersiveSpaceWrapper")
            if let level = notification.object as? Double {
                print("📡 Level extracted: \(level)")
                withAnimation(.easeInOut(duration: 0.5)) {
                    immersionLevel = level
                }
                print("🎛️ Immersion set to \(String(format: "%.0f%%", level * 100)) from main window")
                print("🎛️ Background opacity should be: \(level * 0.8)")
            } else {
                print("❌ Failed to extract level from notification object: \(String(describing: notification.object))")
            }
        }
        .onChange(of: immersionLevel) { oldValue, newValue in
            print("📊 Immersion level changed from \(String(format: "%.2f", oldValue)) to \(String(format: "%.2f", newValue))")
            if abs(newValue - oldValue) > 0.5 {
                print("⚠️ Large immersion jump detected! This might indicate an issue.")
            }
        }
    }
}

/// Immersive content view with digital crown support (now without background overlay)
struct ImmersiveContentView: View {
    @Binding var activeFiles: [String]
    let onClose: (String) -> Void
    @Binding var immersionLevel: Double
    @Binding var showDebugInfo: Bool
    @Environment(AppModel.self) private var appModel
    var collaborativeSession: CollaborativeSessionManager? = nil

    var body: some View {
        ZStack {
            // Static surface detection layer - completely independent
            StaticSurfaceView()
                .environment(appModel)
                .opacity(1.0 - immersionLevel * 0.5) // Fade out surface detection slightly
                .animation(.easeInOut(duration: 0.3), value: immersionLevel)

            // Dynamic diagrams layer - updates when activeFiles changes
            Group {
                ForEach(activeFiles, id: \.self) { file in
                    ContentView(filename: file, onClose: {
                        onClose(file)
                    }, collaborativeSession: collaborativeSession)
                }
            }
            .environment(appModel)
            .opacity(1.0 - immersionLevel * 0.3) // Slightly fade diagrams for immersion
            .animation(.easeInOut(duration: 0.3), value: immersionLevel)
            
        }
        .gesture(
            // Simulate digital crown with vertical drag gesture
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let sensitivity = 0.002 // Adjust sensitivity as needed
                    let delta = -Double(value.translation.height) * sensitivity
                    let newLevel = max(0.0, min(1.0, immersionLevel + delta))
                    
                    withAnimation(.easeOut(duration: 0.1)) {
                        immersionLevel = newLevel
                    }
                }
        )
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


// Note: The actual app entry point is in PlatformApp.swift
// AVAR2_Legacy has been removed to avoid confusion
