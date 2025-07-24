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

extension Notification.Name {
    static let setImmersionLevel = Notification.Name("setImmersionLevel")
}

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
    let activeFiles: [String]
    let onClose: (String) -> Void
    @Environment(AppModel.self) private var appModel
    @State private var immersionLevel: Double = 0.25
    @State private var showDebugInfo: Bool = false
    @State private var lastUpdateLevel: Double = -1.0 // Track last updated level
    
    var body: some View {
        ZStack {
            // Full immersive space background - positioned correctly in world space
            RealityView { content in
                // Create a very large inside-out sphere that surrounds the user completely
                let backgroundEntity = Entity()
                let mesh = MeshResource.generateSphere(radius: 1000) // Extremely large radius
                
                // Use PhysicallyBasedMaterial for better transparency support
                var material = PhysicallyBasedMaterial()
                let alphaValue = Float(max(0.0, immersionLevel * 0.8))
                material.baseColor = .init(tint: .black.withAlphaComponent(CGFloat(alphaValue)), texture: nil)
                material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(floatLiteral: alphaValue))
                
                backgroundEntity.components.set(ModelComponent(mesh: mesh, materials: [material]))
                
                // Position at user's location (0,0,0 in immersive space)
                backgroundEntity.position = [0, 0, 0]
                // Scale negative to make it inside-out (we see the inner surface)
                backgroundEntity.scale = SIMD3<Float>(-1, 1, 1)
                backgroundEntity.name = "immersiveBackgroundSphere"
                
                content.add(backgroundEntity)
                print("🌐 Immersive background sphere created:")
                print("   - Immersion level: \(immersionLevel)")
                print("   - Alpha value: \(alphaValue)")
                print("   - Expected opacity: \(immersionLevel * 0.8 * 100)%")
            } update: { content in
                // Only update if immersion level has actually changed
                guard abs(immersionLevel - lastUpdateLevel) > 0.001 else { return }
                
                // Update background opacity
                if let bg = content.entities.first(where: { $0.name == "immersiveBackgroundSphere" }),
                   var modelComponent = bg.components[ModelComponent.self] {
                    
                    // Use PhysicallyBasedMaterial for better transparency support
                    var material = PhysicallyBasedMaterial()
                    let alphaValue = Float(max(0.0, immersionLevel * 0.8))
                    material.baseColor = .init(tint: .black.withAlphaComponent(CGFloat(alphaValue)), texture: nil)
                    material.blending = .transparent(opacity: PhysicallyBasedMaterial.Opacity(floatLiteral: alphaValue))
                    
                    modelComponent.materials = [material]
                    bg.components.set(modelComponent)
                    
                    // Update the last update level and log only when actually changing
                    lastUpdateLevel = immersionLevel
                    print("🔄 Immersive background updated:")
                    print("   - Immersion level: \(immersionLevel)")
                    print("   - Alpha value: \(alphaValue)")
                    print("   - Expected opacity: \(immersionLevel * 0.8 * 100)%")
                }
            }
            
            // The actual content (diagrams, surface detection)
            ImmersiveContentView(activeFiles: activeFiles, onClose: onClose, immersionLevel: $immersionLevel, showDebugInfo: $showDebugInfo)
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
    let activeFiles: [String]
    let onClose: (String) -> Void
    @Binding var immersionLevel: Double
    @Binding var showDebugInfo: Bool
    @Environment(AppModel.self) private var appModel
    
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
                    ContentView(filename: file) {
                        onClose(file)
                    }
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

@main
struct AVAR2: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var appModel = AppModel()

    enum InputMode: String {
        case file, json
    }

    // Gather all example files in the bundle (without extension)
    let files: [String]
    @State private var selectedFile: String
    @State private var hasEnteredImmersive: Bool = false
    /// List of diagrams currently loaded into the immersive space
    @State private var activeFiles: [String] = []
    /// Track if app has launched to start immersive space automatically
    @State private var hasLaunched: Bool = false
    @StateObject private var fpsMonitor = FPSMonitor()

    @State private var inputMode: InputMode = .file
    @State private var jsonInput: String = ""
    @State private var isJSONValid: Bool = false
    @Environment(\.scenePhase) private var scenePhase


    init() {
        // Find all .txt resources in the main bundle
        let names = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        self.files = names
        // Default to first file if available
        _selectedFile = State(initialValue: names.first ?? "")
    }

    var body: some SwiftUI.Scene {
        // 1. 2D launcher
        WindowGroup {
            VStack(spacing: 20) {
                Text("Launch Immersive Experience")
                    .font(.title)
                    .padding(.top)

                Picker("Input Source", selection: $inputMode) {
                    Text("From File").tag(InputMode.file)
                    Text("From JSON").tag(InputMode.json)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if inputMode == .file {
                    Picker("Select Example", selection: $selectedFile) {
                        ForEach(files, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                } else {
                    VStack(alignment: .leading) {
                        Text("Paste JSON Diagram:")
                            .font(.headline)
                            .padding(.horizontal)

                        TextEditor(text: $jsonInput)
                            .frame(height: UIFont.preferredFont(forTextStyle: .body).lineHeight * 10 + 32)
                            .padding(.horizontal)

                        HStack {
                            Button("Validate JSON") {
                                if let data = jsonInput.data(using: .utf8) {
                                    isJSONValid = (try? JSONSerialization.jsonObject(with: data)) != nil
                                } else {
                                    isJSONValid = false
                                }
                            }

                            Spacer()

                            Button("Clear") {
                                jsonInput = ""
                                isJSONValid = false
                            }
                        }
                        .padding(.horizontal)

                        if !isJSONValid && !jsonInput.isEmpty {
                            Text("Invalid JSON format")
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                    }
                }

                Button("Add Diagram") {
                    Task {
                        if inputMode == .json && !isJSONValid {
                            return // Prevent invalid input
                        }

                        // Ensure immersive space is open
                        if !hasEnteredImmersive {
                            print("🔄 Immersive space not open, opening now...")
                            do {
                                await openImmersiveSpace(id: "MainImmersive")
                                hasEnteredImmersive = true
                                print("✅ Immersive space opened for diagram")
                            } catch {
                                print("❌ Failed to open immersive space for diagram: \(error)")
                                return
                            }
                        }

                        let newFile = inputMode == .file ? selectedFile : "input_json_\(UUID().uuidString)"
                        if inputMode == .json {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(newFile).appendingPathExtension("txt")
                            try? jsonInput.write(to: tempURL, atomically: true, encoding: .utf8)
                        }
                        print("📊 Adding diagram: \(newFile)")
                        activeFiles.append(newFile)
                    }
                }
                .font(.title2)

                Button("Exit Immersive Space") {
                    Task {
                        await dismissImmersiveSpace()
                        hasEnteredImmersive = false
                        activeFiles.removeAll()
                        appModel.resetDiagramPositioning()
                    }
                }
                .font(.title2)
                
                // Debug: Toggle plane visualization
                Button(appModel.showPlaneVisualization ? "Hide Plane Visualization" : "Show Plane Visualization") {
                    appModel.togglePlaneVisualization()
                }
                .font(.title3)
                .foregroundColor(.secondary)
                
                // Immersion Test Buttons
                VStack(spacing: 12) {
                    Text("Immersion Test Controls")
                        .font(.headline)
                        .foregroundColor(.blue)
                    
                    HStack(spacing: 10) {
                        Button("0%") {
                            print("🔘 0% button pressed - sending notification")
                            NotificationCenter.default.post(name: .setImmersionLevel, object: 0.0)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("25%") {
                            print("🔘 25% button pressed - sending notification")
                            NotificationCenter.default.post(name: .setImmersionLevel, object: 0.25)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("50%") {
                            print("🔘 50% button pressed - sending notification")
                            NotificationCenter.default.post(name: .setImmersionLevel, object: 0.5)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("75%") {
                            print("🔘 75% button pressed - sending notification")
                            NotificationCenter.default.post(name: .setImmersionLevel, object: 0.75)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("100%") {
                            print("🔘 100% button pressed - sending notification")
                            NotificationCenter.default.post(name: .setImmersionLevel, object: 1.0)
                        }
                        .buttonStyle(.bordered)
                    }
                    
//                    // Immersion Controls Instructions
//                    VStack(alignment: .leading, spacing: 4) {
//                        Text("In Immersive Space:")
//                            .font(.subheadline)
//                            .fontWeight(.medium)
//                        
//                        Group {
//                            Text("• Spacebar: Toggle debug info")
//                            Text("• Up/Down arrows: Adjust immersion")
//                            Text("• R: Reset immersion to 0")
//                            Text("• F: Full immersion (100%)")
//                            Text("• Vertical drag: Smooth immersion control")
//                        }
//                        .font(.caption)
//                        .foregroundColor(.secondary)
//                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                Spacer()
                
                Button("Quit App") {
                    exit(0)
                }
                .font(.title2)
                .foregroundColor(.red)
                
                Text("\(fpsMonitor.fps) FPS")
                    .font(.title)
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .background {
                    exit(0)
                }
            }
            .task {
                // Auto-open immersive space on launch
                if !hasLaunched {
                    hasLaunched = true
                    print("🚀 App launching - starting surface detection...")
                    // Start surface detection BEFORE opening immersive space
                    await appModel.startSurfaceDetectionIfNeeded()
                    
                    print("🎯 Opening immersive space...")
                    do {
                        await openImmersiveSpace(id: "MainImmersive")
                        hasEnteredImmersive = true
                        print("✅ Immersive space opened successfully")
                    } catch {
                        print("❌ Failed to open immersive space: \(error)")
                        hasEnteredImmersive = false
                    }
                }
            }
        }

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            ImmersiveSpaceWrapper(activeFiles: activeFiles) { file in
                activeFiles.removeAll { $0 == file }
            }
            .environment(appModel)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
