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

#if os(visionOS)
struct AVAR2_Legacy: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var appModel = AppModel()
    @StateObject private var httpServer = HTTPServer()
    @StateObject private var collaborativeSession = CollaborativeSessionManager()
    @State private var immersionStyle: ImmersionStyle = .mixed
    @State private var savedPlaneViz: Bool? = nil

    enum InputMode: String {
        case file, json, server
    }

    // Gather all example files in the bundle (without extension)
    let files: [String]
    @State private var selectedFile: String
    @State private var hasEnteredImmersive: Bool = false
    /// List of diagrams currently loaded into the immersive space
    @State private var activeFiles: [String] = []
    /// Track if app has launched to start immersive space automatically
    @State private var hasLaunched: Bool = false

    @State private var inputMode: InputMode = .file
    @State private var jsonInput: String = ""
    @State private var isJSONValid: Bool = false
    @State private var showingCollaborativeSession = false
    @Environment(\.scenePhase) private var scenePhase


    init() {
        print("🚀 AVAR2_Legacy init() called")
        // Find all .txt resources in the main bundle
        let names = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        self.files = names
        // Default to first file if available
        _selectedFile = State(initialValue: names.first ?? "")
        print("🚀 AVAR2_Legacy init() completed")
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
                    Text("HTTP Server").tag(InputMode.server)
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
                } else if inputMode == .json {
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
                } else {
                    // HTTP Server tab
                    HTTPServerTabView(httpServer: httpServer)
                }

                // Collaborative Session Button
                HStack {
                    Button("Collaborative Session") {
                        showingCollaborativeSession = true
                    }
                    .buttonStyle(.bordered)
                    
                    if collaborativeSession.isSessionActive {
                        Text("●")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                    }
                }

                Button("Add Diagram") {
                    Task {
                        if inputMode == .json && !isJSONValid {
                            return // Prevent invalid input
                        }

                        // Ensure immersive space is open
                        guard await ensureImmersiveSpaceActive() else {
                            print("🚫 Unable to present immersive space for manual diagram")
                            return
                        }

                        let newFile = inputMode == .file ? selectedFile : "input_json_\(UUID().uuidString)"
                        if inputMode == .json {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(newFile).appendingPathExtension("txt")
                            try? jsonInput.write(to: tempURL, atomically: true, encoding: .utf8)
                        }
                        print("📊 Adding diagram: \(newFile)")
                        activeFiles.append(newFile)
                        
                        // Share with collaborative session if active
                        if collaborativeSession.isSessionActive {
                            #if os(visionOS)
                            Task {
                                do {
                                    let elements = try DiagramDataLoader.loadScriptOutput(from: newFile).elements
                                    // Get the position for this diagram
                                    let position = appModel.getNextDiagramPosition(for: newFile)
                                    collaborativeSession.shareDiagram(
                                        filename: newFile,
                                        elements: elements,
                                        worldPosition: position,
                                        worldOrientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                                        worldScale: appModel.defaultDiagramScale
                                    )
                                } catch {
                                    print("❌ Failed to share diagram: \(error)")
                                }
                            }
                            #else
                            print("ℹ️ Ignoring share request for \(newFile) on iOS client; receive-only mode")
                            #endif
                        }
                        
                        // Ensure plane visualization starts disabled for new diagrams
                        appModel.showPlaneVisualization = false
                        appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
                .font(.title2)

                
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
                
                // Bottom row buttons - Exit Immersive Space and Show Plane Visualization on the left, Quit App on the right
                HStack {
                    Button("Exit Immersive Space") {
                        Task {
                            await dismissImmersiveSpace()
                            hasEnteredImmersive = false
                            activeFiles.removeAll()
                            appModel.resetDiagramPositioning()
                        }
                    }
                    .font(.title3)
                    
                    Button(appModel.showPlaneVisualization ? "Hide Plane Visualization" : "Show Plane Visualization") {
                        appModel.togglePlaneVisualization()
                    }
                    .font(.title3)
                    .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("Quit App") {
                        exit(0)
                    }
                    .font(.title2)
                    .foregroundColor(.red)
                }
                
                // Isolate FPS display to prevent picker reloads
                FPSDisplayView()
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
            .environment(appModel)
            .sheet(isPresented: $showingCollaborativeSession) {
                CollaborativeSessionView(sessionManager: collaborativeSession)
            }
            .onAppear {
                print("🔧 WindowGroup VStack onAppear called")
                // Set up HTTP server callback immediately on appear
                print("🔧 Setting up HTTP server callback in onAppear")
                httpServer.onJSONReceived = { scriptOutput, rawJSON in
                    print("🎉 CALLBACK INVOKED with \(scriptOutput.elements.count) elements!")
                    Task { @MainActor in
                        // Ensure immersive space is open (re-open if the user closed it)
                        guard await self.ensureImmersiveSpaceActive() else {
                            print("🚫 Unable to present immersive space for HTTP diagram")
                            return
                        }

                        // Handle diagram ID logic
                        if let diagramId = scriptOutput.id {
                            // Diagram has ID - check if it exists
                            if let existingInfo = self.appModel.getDiagramInfo(for: diagramId) {
                                // Diagram exists - update/redraw it
                                print("🔄 Updating existing diagram with ID: \(diagramId)")

                                // Find and remove the existing diagram from activeFiles
                                self.activeFiles.removeAll { $0 == existingInfo.filename }

                                // Create new filename for the update
                                let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for diagram update")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)

                                    print("🔄 Redrawing diagram with ID: \(diagramId)")
                                    self.activeFiles.append(newFile)

                                    // Update AppModel tracking
                                    self.appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)

                                } catch {
                                    print("❌ Failed to save updated HTTP diagram: \(error)")
                                }
                            } else {
                                // New diagram with ID
                                print("➕ Creating new diagram with ID: \(diagramId)")

                                let newFile = "http_diagram_\(diagramId)"
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for new diagram with ID")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)

                                    print("📊 Adding new HTTP diagram: \(newFile)")
                                    let diagramIndex = self.activeFiles.count
                                    self.activeFiles.append(newFile)

                                    // Register in AppModel
                                    self.appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)

                                } catch {
                                    print("❌ Failed to save new HTTP diagram: \(error)")
                                }
                            }
                        } else {
                            // No ID - create new diagram
                            print("➕ Creating new diagram without ID")

                            let newFile = "http_diagram_\(UUID().uuidString.prefix(8))"
                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for new diagram without ID")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)

                                print("✅ File saved to: \(tempURL.path)")
                                print("✅ File exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
                                print("✅ File size: \(data.count) bytes")
                                print("📊 Adding HTTP diagram: \(newFile) to activeFiles")
                                print("📊 Current activeFiles count: \(self.activeFiles.count)")
                                self.activeFiles.append(newFile)
                                print("📊 New activeFiles count: \(self.activeFiles.count)")
                                print("📊 activeFiles content: \(self.activeFiles)")

                            } catch {
                                print("❌ Failed to save HTTP diagram: \(error)")
                            }
                        }

                        // Ensure plane visualization starts disabled for new diagrams
                        self.appModel.showPlaneVisualization = false
                        self.appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
                print("🔧 HTTP server callback setup complete in onAppear")
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .background {
                    exit(0)
                }
            }
            .task {
                print("🔧 .task block started in WindowGroup")
                // Auto-open immersive space on launch
                if !hasLaunched {
                    hasLaunched = true
                    print("🚀 App launching - starting surface detection...")
                    // Start surface detection BEFORE opening immersive space
                    await appModel.startSurfaceDetectionIfNeeded()

                    print("🎯 Opening immersive space...")
                    let opened = await ensureImmersiveSpaceActive()
                    if opened {
                        print("✅ Immersive space opened successfully")
                    }
                }

                // Set up HTTP server callback for automatic diagram loading
                print("🔧 Setting up HTTP server callback")
                httpServer.onJSONReceived = { scriptOutput, rawJSON in
                    print("🎉 CALLBACK INVOKED with \(scriptOutput.elements.count) elements!")
                    Task { @MainActor in
                        // Ensure immersive space is open (re-open if the user closed it)
                        guard await ensureImmersiveSpaceActive() else {
                            print("🚫 Unable to present immersive space for HTTP diagram")
                            return
                        }
                        
                        // Handle diagram ID logic
                        if let diagramId = scriptOutput.id {
                            // Diagram has ID - check if it exists
                            if let existingInfo = appModel.getDiagramInfo(for: diagramId) {
                                // Diagram exists - update/redraw it
                                print("🔄 Updating existing diagram with ID: \(diagramId)")
                                
                                // Find and remove the existing diagram from activeFiles
                                activeFiles.removeAll { $0 == existingInfo.filename }
                                
                                // Create new filename for the update
                                let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"
                                
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for diagram update")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)
                                    
                                    print("🔄 Redrawing diagram with ID: \(diagramId)")
                                    activeFiles.append(newFile)
                                    
                                    // Update AppModel tracking
                                    appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)
                                    
                                } catch {
                                    print("❌ Failed to save updated HTTP diagram: \(error)")
                                }
                            } else {
                                // New diagram with ID
                                print("➕ Creating new diagram with ID: \(diagramId)")
                                
                                let newFile = "http_diagram_\(diagramId)"
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for new diagram with ID")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)
                                    
                                    print("📊 Adding new HTTP diagram: \(newFile)")
                                    let diagramIndex = activeFiles.count
                                    activeFiles.append(newFile)
                                    
                                    // Register in AppModel
                                    appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)
                                    
                                } catch {
                                    print("❌ Failed to save new HTTP diagram: \(error)")
                                }
                            }
                        } else {
                            // No ID - create new diagram
                            print("➕ Creating new diagram without ID")
                            
                            let newFile = "http_diagram_\(UUID().uuidString.prefix(8))"
                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for new diagram without ID")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)

                                print("✅ File saved to: \(tempURL.path)")
                                print("✅ File exists: \(FileManager.default.fileExists(atPath: tempURL.path))")
                                print("✅ File size: \(data.count) bytes")
                                print("📊 Adding HTTP diagram: \(newFile) to activeFiles")
                                print("📊 Current activeFiles count: \(activeFiles.count)")
                                activeFiles.append(newFile)
                                print("📊 New activeFiles count: \(activeFiles.count)")
                                print("📊 activeFiles content: \(activeFiles)")
                                
                            } catch {
                                print("❌ Failed to save HTTP diagram: \(error)")
                            }
                        }
                        
                        // Ensure plane visualization starts disabled for new diagrams
                        appModel.showPlaneVisualization = false
                        appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
                print("🔧 HTTP server callback setup complete")
            }
        }
        .defaultSize(width: 1000, height: 1000)
        .windowResizability(.contentMinSize)

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            ImmersiveSpaceWrapper(activeFiles: $activeFiles, onClose: { file in
                activeFiles.removeAll { $0 == file }
                appModel.freeDiagramPosition(filename: file)
            }, collaborativeSession: collaborativeSession)
            .environment(appModel)
            .onChange(of: String(describing: immersionStyle)) { _, newKey in
                if newKey.localizedCaseInsensitiveContains("Full") {
                    if savedPlaneViz == nil { savedPlaneViz = appModel.showPlaneVisualization }
                    appModel.showPlaneVisualization = false
                    appModel.surfaceDetector.setVisualizationVisible(false)
                } else if newKey.localizedCaseInsensitiveContains("Mixed") {
                    if let restore = savedPlaneViz {
                        appModel.showPlaneVisualization = restore
                        appModel.surfaceDetector.setVisualizationVisible(restore)
                        savedPlaneViz = nil
                    }
                }
            }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
        .immersiveEnvironmentBehavior(.coexist)
    }
}
#endif

#if os(visionOS)
private extension AVAR2_Legacy {
    /// Makes sure an immersive space is active. If the user has closed it, we re-open it.
    @MainActor
    func ensureImmersiveSpaceActive() async -> Bool {
        if hasEnteredImmersive {
            return true
        }   
        do {
            try await openImmersiveSpace(id: "MainImmersive")
            hasEnteredImmersive = true
            return true
        } catch {
            print("❌ Failed to open immersive space: \(error.localizedDescription)")
            hasEnteredImmersive = false
            return false
        }
    }
}
#endif
