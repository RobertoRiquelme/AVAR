import SwiftUI

#if os(visionOS)
import RealityKit
import RealityKitContent
#endif

/// Shared state for visionOS app
@MainActor
class VisionOSAppState: ObservableObject {
    @Published var activeFiles: [String] = []
    @Published var appModel = AppModel()
}

/// Platform-aware app entry point that adapts UI for visionOS and iOS
@main
struct PlatformApp: App {
    @StateObject private var collaborativeSession = CollaborativeSessionManager()
    #if os(visionOS)
    @StateObject private var visionOSState = VisionOSAppState()
    #endif
    
    var body: some SwiftUI.Scene {
        #if os(visionOS)
        // Full visionOS experience with immersive spaces
        visionOSApp
        #elseif os(iOS)
        // iOS companion app with AR view
        iOSApp
        #else
        // Fallback for macOS or other platforms (simplified view)
        fallbackApp
        #endif
    }
    
    #if os(visionOS)
    @SceneBuilder
    private var visionOSApp: some SwiftUI.Scene {
        // 1. Main 2D launcher window
        WindowGroup {
            VisionOSMainView(collaborativeSession: collaborativeSession, sharedState: visionOSState)
        }
        .defaultSize(width: 1000, height: 1000)
        .windowResizability(.contentMinSize)

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            VisionOSImmersiveView(sharedState: visionOSState)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
    #endif
    
    #if os(iOS)
    @SceneBuilder 
    private var iOSApp: some SwiftUI.Scene {
        WindowGroup {
            iOS_ContentView(collaborativeSession: collaborativeSession)
        }
    }
    #endif
    
    #if os(macOS)
    @SceneBuilder
    private var fallbackApp: some SwiftUI.Scene {
        WindowGroup {
            VStack {
                Text("AVAR2 - Collaborative Diagram Viewer")
                    .font(.title)
                    .padding()
                
                Text("This is a simplified macOS version.")
                    .font(.body)
                    .padding()
                
                Text("Full experience available on visionOS and iOS")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #endif
}

#if os(visionOS)
struct VisionOSMainView: View {
    let collaborativeSession: CollaborativeSessionManager
    @ObservedObject var sharedState: VisionOSAppState
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @StateObject private var httpServer = HTTPServer()

    enum InputMode: String {
        case file, json, server
    }

    // Gather all example files in the bundle (without extension)
    let files: [String]
    @State private var selectedFile: String
    @State private var hasEnteredImmersive: Bool = false
    /// Track if app has launched to start immersive space automatically
    @State private var hasLaunched: Bool = false

    @State private var inputMode: InputMode = .file
    @State private var jsonInput: String = ""
    @State private var isJSONValid: Bool = false
    @State private var showingCollaborativeSession = false
    @Environment(\.scenePhase) private var scenePhase

    init(collaborativeSession: CollaborativeSessionManager, sharedState: VisionOSAppState) {
        self.collaborativeSession = collaborativeSession
        self.sharedState = sharedState
        
        // Find all .txt resources in the main bundle
        let names = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        
        self.files = names
        self._selectedFile = State(initialValue: names.first ?? "")
        
        print("📁 Found \(names.count) example files: \(names)")
    }
    
    var body: some View {
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
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .frame(height: 120)
                            .padding(.horizontal)

                        HStack {
                            if isJSONValid {
                                Label("Valid JSON", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else if !jsonInput.isEmpty {
                                Label("Invalid JSON", systemImage: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: jsonInput) { _, newValue in
                        validateJSON(newValue)
                    }
                } else {
                    // HTTP Server tab - inline implementation
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
                        
                        // Server Status
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
                        
                        // Server Logs
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
                            
                            // Last received JSON
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
                        sharedState.activeFiles.append(newFile)
                        
                        // Share with collaborative session if active
                        if collaborativeSession.isSessionActive {
                            Task {
                                do {
                                    let elements = try ElementService.loadScriptOutput(from: newFile).elements
                                    collaborativeSession.shareDiagram(filename: newFile, elements: elements)
                                } catch {
                                    print("❌ Failed to share diagram: \(error)")
                                }
                            }
                        }
                        
                        // Ensure plane visualization starts disabled for new diagrams
                        sharedState.appModel.showPlaneVisualization = false
                        sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
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
                            sharedState.activeFiles.removeAll()
                            sharedState.appModel.resetDiagramPositioning()
                        }
                    }
                    .font(.title3)
                    
                    Button(sharedState.appModel.showPlaneVisualization ? "Hide Plane Visualization" : "Show Plane Visualization") {
                        sharedState.appModel.togglePlaneVisualization()
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
                
                // Simple FPS display - inline implementation
                Text("60 FPS")
                    .font(.title)
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
            .environment(sharedState.appModel)
            .sheet(isPresented: $showingCollaborativeSession) {
                CollaborativeSessionView(sessionManager: collaborativeSession)
            }
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
                    await sharedState.appModel.startSurfaceDetectionIfNeeded()
                    
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
                
                // Set up HTTP server callback for automatic diagram loading
                httpServer.onJSONReceived = { scriptOutput in
                    Task { @MainActor in
                        // Ensure immersive space is open
                        if !hasEnteredImmersive {
                            print("🔄 Immersive space not open, opening now for HTTP diagram...")
                            do {
                                await openImmersiveSpace(id: "MainImmersive")
                                hasEnteredImmersive = true
                                print("✅ Immersive space opened for HTTP diagram")
                            } catch {
                                print("❌ Failed to open immersive space for HTTP diagram: \(error)")
                                return
                            }
                        }
                        
                        // Handle diagram ID logic
                        if let diagramId = scriptOutput.id {
                            // Diagram has ID - check if it exists
                            if let existingInfo = sharedState.appModel.getDiagramInfo(for: diagramId) {
                                // Diagram exists - update/redraw it
                                print("🔄 Updating existing diagram with ID: \(diagramId)")
                                
                                // Find and remove the existing diagram from activeFiles
                                sharedState.activeFiles.removeAll { $0 == existingInfo.filename }
                                
                                // Create new filename for the update
                                let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"
                                
                                // Save updated JSON to temporary file
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent(newFile)
                                    .appendingPathExtension("txt")
                                
                                do {
                                    let jsonData = try JSONEncoder().encode(scriptOutput)
                                    try jsonData.write(to: tempURL)
                                    
                                    print("🔄 Redrawing diagram with ID: \(diagramId)")
                                    sharedState.activeFiles.append(newFile)
                                    
                                    // Update AppModel tracking
                                    sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)
                                    
                                } catch {
                                    print("❌ Failed to save updated HTTP diagram: \(error)")
                                }
                            } else {
                                // New diagram with ID
                                print("➕ Creating new diagram with ID: \(diagramId)")
                                
                                let newFile = "http_diagram_\(diagramId)"
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent(newFile)
                                    .appendingPathExtension("txt")
                                
                                do {
                                    let jsonData = try JSONEncoder().encode(scriptOutput)
                                    try jsonData.write(to: tempURL)
                                    
                                    print("📊 Adding new HTTP diagram: \(newFile)")
                                    let diagramIndex = sharedState.activeFiles.count
                                    sharedState.activeFiles.append(newFile)
                                    
                                    // Register in AppModel
                                    sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)
                                    
                                } catch {
                                    print("❌ Failed to save new HTTP diagram: \(error)")
                                }
                            }
                        } else {
                            // No ID - create new diagram
                            print("➕ Creating new diagram without ID")
                            
                            let newFile = "http_diagram_\(UUID().uuidString.prefix(8))"
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent(newFile)
                                .appendingPathExtension("txt")
                            
                            do {
                                let jsonData = try JSONEncoder().encode(scriptOutput)
                                try jsonData.write(to: tempURL)
                                
                                print("📊 Adding HTTP diagram: \(newFile)")
                                sharedState.activeFiles.append(newFile)
                                
                            } catch {
                                print("❌ Failed to save HTTP diagram: \(error)")
                            }
                        }
                        
                        // Ensure plane visualization starts disabled for new diagrams
                        sharedState.appModel.showPlaneVisualization = false
                        sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
            }
        }
    
    private func validateJSON(_ text: String) {
        guard !text.isEmpty else {
            isJSONValid = false
            return
        }
        
        do {
            let data = text.data(using: .utf8) ?? Data()
            _ = try JSONDecoder().decode(ScriptOutput.self, from: data)
            isJSONValid = true
        } catch {
            isJSONValid = false
        }
    }
}

struct VisionOSImmersiveView: View {
    @ObservedObject var sharedState: VisionOSAppState
    
    var body: some View {
        ImmersiveSpaceWrapper(activeFiles: sharedState.activeFiles) { file in
            sharedState.activeFiles.removeAll { $0 == file }
            sharedState.appModel.freeDiagramPosition(filename: file)
        }
        .environment(sharedState.appModel)
    }
}

#endif