import SwiftUI
import simd

#if os(visionOS)
import RealityKit
import RealityKitContent
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GroupActivities)
import GroupActivities
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
    @State private var immersionStyleVisionOS: ImmersionStyle = .mixed
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
            VisionOSImmersiveView(sharedState: visionOSState, collaborativeSession: collaborativeSession, immersionStyle: immersionStyleVisionOS)
        }
        .immersionStyle(selection: $immersionStyleVisionOS, in: .mixed, .full)
        .immersiveEnvironmentBehavior(.coexist)
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
    @ObservedObject var collaborativeSession: CollaborativeSessionManager
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
    @State private var didCopyJSON = false
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

                #if os(visionOS)
                HStack(spacing: 12) {
                    let hasAnchor = collaborativeSession.sharedAnchor != nil
                    Label("Shared Space", systemImage: hasAnchor ? "checkmark.seal.fill" : "person.3.sequence")
                        .foregroundColor(hasAnchor ? .green : .secondary)
                    if let anchor = collaborativeSession.sharedAnchor {
                        Text(anchor.id.prefix(6))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: .capsule)
                    } else {
                        Text("Awaiting anchor").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        broadcastSharedAnchor()
                    } label: {
                        Label("Broadcast", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                #endif


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

                // Collaborative Session Button
                HStack {
                    Button("Collaborative Session") {
                        showingCollaborativeSession = true
                    }
                    .buttonStyle(.bordered)

                    // Share button for visionOS 26+ immersive space sharing
                    #if os(visionOS)
                    if #available(visionOS 26.0, *) {
                        Button {
                            Task {
                                await startSharePlayForImmersiveSpace()
                            }
                        } label: {
                            Label("Share Space", systemImage: "shareplay")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        // Toggle for spatial personas vs full interaction
                        Toggle(isOn: $collaborativeSession.useSpatialPersonas) {
                            Label(
                                collaborativeSession.useSpatialPersonas ? "Personas" : "Interact",
                                systemImage: collaborativeSession.useSpatialPersonas ? "person.2.fill" : "hand.draw.fill"
                            )
                            .font(.caption)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .help(collaborativeSession.useSpatialPersonas
                              ? "Spatial Personas: See other users, but no diagram gestures"
                              : "Full Interaction: Diagram gestures work, but no personas")
                    }
                    #endif

                    if collaborativeSession.isSessionActive || collaborativeSession.isSharePlayActive {
                        HStack(spacing: 4) {
                            Text("●")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            if collaborativeSession.isSharePlayActive {
                                Text("SharePlay")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
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
                        sharedState.activeFiles.append(newFile)
                        
                        // Share with collaborative session if active
                        if collaborativeSession.isSessionActive {
                            Task {
                                do {
                                    let elements = try DiagramDataLoader.loadScriptOutput(from: newFile).elements
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

                            // Also leave SharePlay session if active
                            #if canImport(GroupActivities)
                            if collaborativeSession.isSharePlayActive {
                                collaborativeSession.stopSharePlay()
                                print("🛑 Left SharePlay session after closing immersive space")
                            }
                            #endif
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
            .onAppear {
                print("🔧 VisionOSMainView.onAppear called!")
                // Set up HTTP server callback IMMEDIATELY on appear
                print("🔧 Setting httpServer.onJSONReceived callback NOW")
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
                            if let existingInfo = self.sharedState.appModel.getDiagramInfo(for: diagramId) {
                                // Diagram exists - update/redraw it
                                print("🔄 Updating existing diagram with ID: \(diagramId)")

                                // Find and remove the existing diagram from activeFiles
                                self.sharedState.activeFiles.removeAll { $0 == existingInfo.filename }

                                // Create new filename for the update
                                let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                                // Save updated JSON to temporary file
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for diagram update")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)

                                    print("🔄 Redrawing diagram with ID: \(diagramId)")
                                    self.sharedState.activeFiles.append(newFile)

                                    // Update AppModel tracking
                                    self.sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)

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
                                    let diagramIndex = self.sharedState.activeFiles.count
                                    self.sharedState.activeFiles.append(newFile)

                                    // Register in AppModel
                                    self.sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)

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

                                print("📊 Adding HTTP diagram: \(newFile)")
                                self.sharedState.activeFiles.append(newFile)

                            } catch {
                                print("❌ Failed to save HTTP diagram: \(error)")
                            }
                        }

                        print("🔥 Final activeFiles count: \(self.sharedState.activeFiles.count)")
                        print("🔥 Callback complete - SwiftUI should now update the view")

                        // Ensure plane visualization starts disabled for new diagrams
                        self.sharedState.appModel.showPlaneVisualization = false
                        self.sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
                print("🔧 HTTP server callback setup complete!")

                // Set up SharePlay callback to check if we have diagrams open
                #if canImport(GroupActivities)
                collaborativeSession.sharePlayCoordinator?.getHasDiagramsOpen = { [weak sharedState] in
                    !(sharedState?.activeFiles.isEmpty ?? true)
                }
                #endif
            }
            .task {
                print("🔧 VisionOSMainView.task called!")
                // Auto-open immersive space on launch
                if !hasLaunched {
                    hasLaunched = true
                    print("🚀 App launching - starting surface detection...")
                    // Start surface detection BEFORE opening immersive space
                    await sharedState.appModel.startSurfaceDetectionIfNeeded()

                    print("🎯 Opening immersive space...")
                    let opened = await ensureImmersiveSpaceActive()
                    if opened {
                        print("✅ Immersive space opened successfully")
                    }
                }

                // Set up HTTP server callback for automatic diagram loading (kept as backup)
                print("🔧 Setting httpServer.onJSONReceived callback in .task (backup)")
                httpServer.onJSONReceived = { scriptOutput, rawJSON in
                    print("🎉 CALLBACK INVOKED FROM .task with \(scriptOutput.elements.count) elements!")
                    Task { @MainActor in
                        // Ensure immersive space is open (re-open if the user closed it)
                        guard await ensureImmersiveSpaceActive() else {
                            print("🚫 Unable to present immersive space for HTTP diagram")
                            return
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
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for diagram update")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)
                                    
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
                                do {
                                    guard let data = rawJSON.data(using: .utf8) else {
                                        print("❌ Failed to convert raw JSON to data for new diagram with ID")
                                        return
                                    }
                                    let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                    try data.write(to: tempURL)
                                    
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
                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for new diagram without ID")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)
                                
                                print("📊 Adding HTTP diagram: \(newFile)")
                                sharedState.activeFiles.append(newFile)

                            } catch {
                                print("❌ Failed to save HTTP diagram: \(error)")
                            }
                        }

                        print("🔥 Final activeFiles count: \(sharedState.activeFiles.count)")
                        print("🔥 Callback complete - SwiftUI should now update the view")

                        // Ensure plane visualization starts disabled for new diagrams
                        sharedState.appModel.showPlaneVisualization = false
                        sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                    }
                }
            }
            .alert(item: $collaborativeSession.pendingAlert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            #if os(visionOS)
            // React to SharePlay requesting the immersive space to open
            .onChange(of: collaborativeSession.sharePlayRequestsImmersiveSpace) { _, requestsOpen in
                if requestsOpen {
                    Task {
                        print("📢 SharePlay requested immersive space - opening...")
                        let opened = await ensureImmersiveSpaceActive()
                        if opened {
                            print("✅ Immersive space opened for SharePlay")
                            // Ensure plane visualization is disabled for SharePlay
                            // (surfaces can be distracting in shared experiences)
                            if sharedState.appModel.showPlaneVisualization {
                                print("🔧 Disabling plane visualization for SharePlay")
                                sharedState.appModel.showPlaneVisualization = false
                                sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                            }
                        } else {
                            print("❌ Failed to open immersive space for SharePlay")
                        }
                        // Reset the flag
                        collaborativeSession.sharePlayRequestsImmersiveSpace = false
                    }
                }
            }
            // Also disable plane visualization when SharePlay becomes active
            .onChange(of: collaborativeSession.isSharePlayActive) { _, isActive in
                if isActive {
                    print("🔧 SharePlay became active - ensuring plane visualization is disabled")
                    sharedState.appModel.showPlaneVisualization = false
                    sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                }
            }
            #endif
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

#if os(visionOS)
private extension VisionOSMainView {
    func broadcastSharedAnchor() {
        collaborativeSession.broadcastCurrentSharedAnchor()
        if let anchor = collaborativeSession.sharedAnchor {
            print("📡 visionOS broadcast shared anchor \(anchor.id)")
        }
    }

}
#endif

struct VisionOSImmersiveView: View {
    @ObservedObject var sharedState: VisionOSAppState
    @ObservedObject var collaborativeSession: CollaborativeSessionManager
    let immersionStyle: ImmersionStyle
    @State private var showBackgroundOverlay = false
    @State private var savedPlaneViz: Bool? = nil

    var body: some View {
        ImmersiveSpaceWrapper(activeFiles: $sharedState.activeFiles, onClose: { file in
            sharedState.activeFiles.removeAll { $0 == file }
            sharedState.appModel.freeDiagramPosition(filename: file)
            // 🔴 Broadcast removal so peers remove too
            collaborativeSession.removeDiagram(filename: file)
        }, collaborativeSession: collaborativeSession, showBackgroundOverlay: showBackgroundOverlay)
        .environment(sharedState.appModel)
        .onAppear {
            showBackgroundOverlay = false
            if collaborativeSession.sharedAnchor == nil {
                collaborativeSession.broadcastCurrentSharedAnchor()
            }
        }
        .onReceive(collaborativeSession.$sharedDiagrams) { diagrams in
            // Only sync diagrams when SharePlay is active
            guard collaborativeSession.isSharePlayActive else { return }

            let sharedFilenames = Set(diagrams.map { $0.filename })
            let currentFilenames = Set(sharedState.activeFiles)

            // SharePlay host keeps its local diagrams - they are the source of truth
            // Only clients (non-hosts) should sync from sharedDiagrams
            if collaborativeSession.isSharePlayHost {
                print("📊 SharePlay host: keeping \(currentFilenames.count) local diagrams (source of truth)")
                return
            }

            // Safety: Don't remove all diagrams if sharedDiagrams is empty
            // This can happen during view recreation or network delays
            if sharedFilenames.isEmpty && !currentFilenames.isEmpty {
                print("⚠️ Client: sharedDiagrams is empty but we have \(currentFilenames.count) local diagrams - skipping removal")
                return
            }

            // For client devices: sync activeFiles with sharedDiagrams
            // Remove diagrams that are no longer shared
            let diagramsToRemove = currentFilenames.subtracting(sharedFilenames)
            if !diagramsToRemove.isEmpty {
                sharedState.activeFiles.removeAll { diagramsToRemove.contains($0) }
                print("🗑️ Client: removed \(diagramsToRemove.count) diagrams no longer in shared list")
            }

            // Add new shared diagrams that aren't already active
            for diagram in diagrams {
                if !currentFilenames.contains(diagram.filename) {
                    // Save the diagram elements to a temporary file so ContentView can load them
                    // Include the shared position so the client places it correctly
                    Task { @MainActor in
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = .prettyPrinted

                            // Build diagram data including position for client to use
                            var diagramData: [String: Any] = ["elements": diagram.elements.map { element -> [String: Any] in
                                let elementData = try! encoder.encode(element)
                                return try! JSONSerialization.jsonObject(with: elementData) as! [String: Any]
                            }]

                            // Include shared position so client can place diagram correctly
                            if let pos = diagram.worldPosition {
                                diagramData["sharedPosition"] = ["x": pos.x, "y": pos.y, "z": pos.z]
                            }
                            if let orient = diagram.worldOrientation {
                                diagramData["sharedOrientation"] = [
                                    "x": orient.imag.x, "y": orient.imag.y, "z": orient.imag.z, "w": orient.real
                                ]
                            }
                            if let scale = diagram.worldScale {
                                diagramData["sharedScale"] = scale
                            }

                            let data = try JSONSerialization.data(withJSONObject: diagramData, options: .prettyPrinted)
                            let tempURL = try DiagramStorage.fileURL(for: diagram.filename, withExtension: "txt")
                            try data.write(to: tempURL)

                            print("📥 Client: Adding shared diagram '\(diagram.filename)' with \(diagram.elements.count) elements at position: \(diagram.worldPosition?.description ?? "nil")")
                            if !sharedState.activeFiles.contains(diagram.filename) {
                                sharedState.activeFiles.append(diagram.filename)
                            }
                        } catch {
                            print("❌ Failed to save shared diagram '\(diagram.filename)': \(error)")
                        }
                    }
                }
            }
        }
        .onChange(of: String(describing: immersionStyle)) { _, newKey in
            if newKey.localizedCaseInsensitiveContains("Full") {
                if savedPlaneViz == nil { savedPlaneViz = sharedState.appModel.showPlaneVisualization }
                sharedState.appModel.showPlaneVisualization = false
                sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
            } else if newKey.localizedCaseInsensitiveContains("Mixed") {
                if let restore = savedPlaneViz {
                    sharedState.appModel.showPlaneVisualization = restore
                    sharedState.appModel.surfaceDetector.setVisualizationVisible(restore)
                    savedPlaneViz = nil
                }
                showBackgroundOverlay = false
            }
        }
        .overlay(alignment: .topLeading) {
            if let anchor = collaborativeSession.sharedAnchor {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Shared Anchor", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("ID: \(anchor.id.prefix(6))")
                        .font(.caption)
                    Text(String(format: "Confidence: %.2f", anchor.confidence))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            } else {
                Label("Awaiting Shared Anchor", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
    }
}

#endif

#if os(visionOS)
private extension VisionOSMainView {
    /// Starts SharePlay for sharing the immersive space with nearby people (visionOS 26+)
    @available(visionOS 26.0, *)
    @MainActor
    func startSharePlayForImmersiveSpace() async {
        // Ensure immersive space is open first
        if !hasEnteredImmersive {
            let opened = await ensureImmersiveSpaceActive()
            if !opened {
                print("❌ Cannot start SharePlay: failed to open immersive space")
                return
            }
        }

        // Ensure plane visualization stays disabled when starting share
        // (Don't change the user's preference, just ensure surfaces aren't shown)
        let currentVisualization = sharedState.appModel.showPlaneVisualization
        if currentVisualization {
            print("⚠️ Plane visualization was enabled, keeping user preference")
        }

        // Share any existing diagrams that are already loaded
        // This ensures diagrams loaded before sharing starts are visible to peers
        await shareExistingDiagrams()

        // Activate the SharePlay activity - this will prompt the share menu
        let activity = SharedSpaceActivity()
        _ = try? await activity.activate()
        print("✅ SharePlay activity activated for immersive space sharing")
    }

    /// Share all currently loaded diagrams with the collaborative session
    @MainActor
    func shareExistingDiagrams() async {
        guard !sharedState.activeFiles.isEmpty else {
            print("📊 No existing diagrams to share")
            return
        }

        print("📊 Sharing \(sharedState.activeFiles.count) existing diagrams...")

        for filename in sharedState.activeFiles {
            do {
                let output = try DiagramDataLoader.loadScriptOutput(from: filename)
                // Get the current position of the diagram from the AppModel if available
                let position = sharedState.appModel.getDiagramPosition(for: filename)

                collaborativeSession.shareDiagram(
                    filename: filename,
                    elements: output.elements,
                    worldPosition: position,
                    worldOrientation: nil,
                    worldScale: nil
                )
                print("📤 Shared existing diagram: \(filename)")
            } catch {
                print("❌ Failed to share existing diagram \(filename): \(error)")
            }
        }
    }

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
#endif
