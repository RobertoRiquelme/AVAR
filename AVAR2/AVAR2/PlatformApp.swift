//
//  PlatformApp.swift
//  AVAR2
//

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
        visionOSApp
        #elseif os(iOS)
        iOSApp
        #else
        fallbackApp
        #endif
    }

    #if os(visionOS)
    @SceneBuilder
    private var visionOSApp: some SwiftUI.Scene {
        WindowGroup {
            VisionOSMainView(collaborativeSession: collaborativeSession, sharedState: visionOSState)
        }
        .defaultSize(width: 1000, height: 1000)
        .windowResizability(.contentMinSize)

        ImmersiveSpace(id: "MainImmersive") {
            VisionOSImmersiveView(
                sharedState: visionOSState,
                collaborativeSession: collaborativeSession,
                immersionStyle: immersionStyleVisionOS
            )
        }
        .immersionStyle(selection: $immersionStyleVisionOS, in: .mixed, .full)
        .immersiveEnvironmentBehavior(.coexist)
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

    @State private var showingDiagramChooser = false

    @Environment(\.scenePhase) private var scenePhase

    init(collaborativeSession: CollaborativeSessionManager, sharedState: VisionOSAppState) {
        self.collaborativeSession = collaborativeSession
        self.sharedState = sharedState

        let names = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []

        self.files = names
        self._selectedFile = State(initialValue: names.first ?? "")

        print("📁 Found \(names.count) example files: \(names)")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("AVAR — Launch Immersive Experience")
                .font(.title)
                .padding(.top, 6)

            // ✅ Collaboration (expandable, fixed height so the UI doesn't resize)
            CollaborationCard(
                collaborativeSession: collaborativeSession,
                onBroadcast: { broadcastSharedAnchor() },
                onOpenCollabSession: { showingCollaborativeSession = true },
                onStartShareSpace: {
                    Task {
                        if #available(visionOS 26.0, *) {
                            await startSharePlayForImmersiveSpace()
                        }
                    }
                }
            )
            .padding(.horizontal)

            // ✅ Input (mode-dependent, collab stays stable)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Input Source", selection: $inputMode) {
                        Text("From File").tag(InputMode.file)
                        Text("From JSON").tag(InputMode.json)
                        Text("HTTP Server").tag(InputMode.server)
                    }
                    .pickerStyle(.segmented)

                    if inputMode == .file {
                        filePickerSection
                    } else if inputMode == .json {
                        jsonSection
                    } else {
                        serverSection
                    }

                    HStack {
                        if inputMode != .server {
                            Button {
                                Task {
                                    if inputMode == .json && !isJSONValid { return }

                                    if !hasEnteredImmersive {
                                        do {
                                            await openImmersiveSpace(id: "MainImmersive")
                                            hasEnteredImmersive = true
                                        } catch {
                                            print("❌ Failed to open immersive space for diagram: \(error)")
                                            return
                                        }
                                    }

                                    let newFile = (inputMode == .file) ? selectedFile : "input_json_\(UUID().uuidString)"
                                    if inputMode == .json {
                                        let tempURL = FileManager.default.temporaryDirectory
                                            .appendingPathComponent(newFile)
                                            .appendingPathExtension("txt")
                                        try? jsonInput.write(to: tempURL, atomically: true, encoding: .utf8)
                                    }

                                    sharedState.activeFiles.append(newFile)

                                    if collaborativeSession.isSessionActive {
                                        do {
                                            let elements = try DiagramDataLoader.loadScriptOutput(from: newFile).elements
                                            collaborativeSession.shareDiagram(filename: newFile, elements: elements)
                                        } catch {
                                            print("❌ Failed to share diagram: \(error)")
                                        }
                                    }

                                    sharedState.appModel.showPlaneVisualization = false
                                    sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                                }
                            } label: {
                                Label("Add Diagram", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(inputMode == .file && selectedFile.isEmpty)

                            Spacer()
                        } else {
                            Label("Auto-import from server", systemImage: "bolt.horizontal.circle")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .foregroundStyle(.secondary)

                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Input", systemImage: "tray.and.arrow.down")
            }
            .padding(.horizontal)

            Spacer(minLength: 0)

            bottomBar

            Text("60 FPS")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .groupBoxStyle(RoundedCardGroupBoxStyle()) // ✅ rounder cards everywhere
        .padding()
        .contentShape(Rectangle())
        .environment(sharedState.appModel)
        .sheet(isPresented: $showingCollaborativeSession) {
            CollaborativeSessionView(sessionManager: collaborativeSession)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { exit(0) }
        }
        .onAppear {
            print("🔧 VisionOSMainView.onAppear called!")
            print("🔧 Setting httpServer.onJSONReceived callback NOW")
            httpServer.onJSONReceived = { scriptOutput, rawJSON in
                print("🎉 CALLBACK INVOKED with \(scriptOutput.elements.count) elements!")
                Task { @MainActor in
                    guard await self.ensureImmersiveSpaceActive() else {
                        print("🚫 Unable to present immersive space for HTTP diagram")
                        return
                    }

                    if let diagramId = scriptOutput.id {
                        if let existingInfo = self.sharedState.appModel.getDiagramInfo(for: diagramId) {
                            print("🔄 Updating existing diagram with ID: \(diagramId)")
                            self.sharedState.activeFiles.removeAll { $0 == existingInfo.filename }
                            let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for diagram update")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)
                                print("🔄 Redrawing diagram with ID: \(diagramId)")
                                self.sharedState.activeFiles.append(newFile)
                                self.sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)
                            } catch {
                                print("❌ Failed to save updated HTTP diagram: \(error)")
                            }
                        } else {
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
                                self.sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)
                            } catch {
                                print("❌ Failed to save new HTTP diagram: \(error)")
                            }
                        }
                    } else {
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

                    self.sharedState.appModel.showPlaneVisualization = false
                    self.sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                }
            }
            print("🔧 HTTP server callback setup complete!")

            #if canImport(GroupActivities)
            collaborativeSession.sharePlayCoordinator?.getHasDiagramsOpen = { [weak sharedState] in
                !(sharedState?.activeFiles.isEmpty ?? true)
            }
            #endif
        }
        .task {
            print("🔧 VisionOSMainView.task called!")
            if !hasLaunched {
                hasLaunched = true
                print("🚀 App launching - starting surface detection...")
                await sharedState.appModel.startSurfaceDetectionIfNeeded()

                print("🎯 Opening immersive space...")
                let opened = await ensureImmersiveSpaceActive()
                if opened {
                    print("✅ Immersive space opened successfully")
                }
            }

            print("🔧 Setting httpServer.onJSONReceived callback in .task (backup)")
            httpServer.onJSONReceived = { scriptOutput, rawJSON in
                print("🎉 CALLBACK INVOKED FROM .task with \(scriptOutput.elements.count) elements!")
                Task { @MainActor in
                    guard await ensureImmersiveSpaceActive() else {
                        print("🚫 Unable to present immersive space for HTTP diagram")
                        return
                    }

                    if let diagramId = scriptOutput.id {
                        if let existingInfo = sharedState.appModel.getDiagramInfo(for: diagramId) {
                            print("🔄 Updating existing diagram with ID: \(diagramId)")
                            sharedState.activeFiles.removeAll { $0 == existingInfo.filename }
                            let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for diagram update")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)

                                print("🔄 Redrawing diagram with ID: \(diagramId)")
                                sharedState.activeFiles.append(newFile)
                                sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: existingInfo.index)
                            } catch {
                                print("❌ Failed to save updated HTTP diagram: \(error)")
                            }
                        } else {
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
                                sharedState.appModel.registerDiagram(id: diagramId, filename: newFile, index: diagramIndex)
                            } catch {
                                print("❌ Failed to save new HTTP diagram: \(error)")
                            }
                        }
                    } else {
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

                    sharedState.appModel.showPlaneVisualization = false
                    sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                }
            }
        }
        .alert(item: $collaborativeSession.pendingAlert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        #if os(visionOS)
        .onChange(of: collaborativeSession.sharePlayRequestsImmersiveSpace) { _, requestsOpen in
            if requestsOpen {
                Task {
                    print("📢 SharePlay requested immersive space - opening...")
                    let opened = await ensureImmersiveSpaceActive()
                    if opened {
                        print("✅ Immersive space opened for SharePlay")
                        if sharedState.appModel.showPlaneVisualization {
                            print("🔧 Disabling plane visualization for SharePlay")
                            sharedState.appModel.showPlaneVisualization = false
                            sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                        }
                    } else {
                        print("❌ Failed to open immersive space for SharePlay")
                    }
                    collaborativeSession.sharePlayRequestsImmersiveSpace = false
                }
            }
        }
        .onChange(of: collaborativeSession.isSharePlayActive) { _, isActive in
            if isActive {
                print("🔧 SharePlay became active - ensuring plane visualization is disabled")
                sharedState.appModel.showPlaneVisualization = false
                sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
            }
        }
        #endif
    }

    // MARK: - Sections (UI)

    private var filePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingDiagramChooser = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(selectedFile.isEmpty ? "Choose a diagram" : selectedFile)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingDiagramChooser) {
                DiagramChooserSheet(files: files, selectedFile: $selectedFile)
                    .presentationDetents([.medium, .large])
            }

            Text("\(files.count) available diagrams")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste JSON Diagram")
                .font(.headline)

            GroupBox {
                TextEditor(text: $jsonInput)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.clear)
            } label: {
                Label("JSON Editor", systemImage: "curlybraces")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 140)

            HStack {
                if isJSONValid {
                    Label("Valid JSON", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else if !jsonInput.isEmpty {
                    Label("Invalid JSON", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    Text(" ")
                        .font(.caption)
                }
                Spacer()
            }
        }
        .onChange(of: jsonInput) { _, newValue in
            validateJSON(newValue)
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    if httpServer.isRunning { httpServer.stop() } else { httpServer.start() }
                } label: {
                    Label(
                        httpServer.isRunning ? "Stop Server" : "Start Server",
                        systemImage: httpServer.isRunning ? "stop.circle.fill" : "play.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if httpServer.isRunning {
                    StatusPill(text: "Running", systemImage: "checkmark.seal.fill", tint: .green)
                } else {
                    StatusPill(text: "Stopped", systemImage: "pause.circle", tint: .secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Status") {
                        Text(httpServer.serverStatus)
                            .foregroundStyle(httpServer.isRunning ? .green : .secondary)
                    }

                    if httpServer.isRunning {
                        LabeledContent("URL") {
                            Text(httpServer.serverURL)
                                .textSelection(.enabled)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            } label: {
                Label("Server", systemImage: "network")
            }

            GroupBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if httpServer.serverLogs.isEmpty {
                                Text("No logs yet")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(Array(httpServer.serverLogs.enumerated()), id: \.offset) { index, log in
                                    Text(log)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 1)
                                        .id(index)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: 140)
                    .onChange(of: httpServer.serverLogs.count) { _, _ in
                        if !httpServer.serverLogs.isEmpty {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(httpServer.serverLogs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }

            if !httpServer.lastReceivedJSON.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Last received payload")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                copyJSONToClipboard(httpServer.lastReceivedJSON)
                            } label: {
                                Label(didCopyJSON ? "Copied" : "Copy",
                                      systemImage: didCopyJSON ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }

                        ScrollView {
                            Text(httpServer.lastReceivedJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .textSelection(.enabled)
                        }
                        .frame(height: 90)

                        if didCopyJSON {
                            Text("Copied to clipboard")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                } label: {
                    Label("Last JSON", systemImage: "curlybraces.square")
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button("Exit Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                    hasEnteredImmersive = false
                    sharedState.activeFiles.removeAll()
                    sharedState.appModel.resetDiagramPositioning()

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

            Button("Quit App") { exit(0) }
                .font(.title2)
                .foregroundColor(.red)
        }
    }

    // MARK: - Validation

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

    // MARK: - Styles / UI Components

    private struct RoundedCardGroupBoxStyle: GroupBoxStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                configuration.label
                    .font(.headline)
                configuration.content
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private struct StatusPill: View {
        let text: String
        let systemImage: String
        let tint: Color

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(text)
            }
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
        }
    }

    // MARK: - Collaboration Card (Expandable, fixed size)

    private struct CollaborationCard: View {
        @ObservedObject var collaborativeSession: CollaborativeSessionManager
        let onBroadcast: () -> Void
        let onOpenCollabSession: () -> Void
        let onStartShareSpace: () -> Void

        @State private var isExpanded: Bool = false

        private var badgeState: ConnectionBadge.State {
            if collaborativeSession.isSharePlayActive { return .shareplay }
            if collaborativeSession.isSessionActive { return .connected }
            return .offline
        }

        private var anchorCode: String {
            if let anchor = collaborativeSession.sharedAnchor {
                return String(anchor.id.prefix(6))
            }
            return "------"
        }

        private var anchorReady: Bool {
            collaborativeSession.sharedAnchor != nil
        }

        var body: some View {
            GroupBox {
                VStack(spacing: 10) {
                    headerRow

                    if isExpanded {
                        Divider()
                            .opacity(0.6)
                            .transition(.opacity)

                        expandedControls
                            .transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .move(edge: .top))
                                        .combined(with: .scale(scale: 0.98, anchor: .top)),
                                    removal: .opacity
                                        .combined(with: .move(edge: .top))
                                )
                            )
                    }

                }
            } label: {
                Label("Collaboration", systemImage: "person.2.wave.2")
            }
        }

        private var headerRow: some View {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Verify Anchor")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    AnchorCodeBadge(code: anchorCode, isReady: anchorReady)

                    Spacer()

                    ConnectionBadge(state: badgeState)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.thinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }


        private var expandedControls: some View {
            HStack(spacing: 10) {
                Button {
                    onOpenCollabSession()
                } label: {
                    Label("Session", systemImage: "person.2")
                }
                .buttonStyle(.bordered)

                // Keep broadcast action clear, but the *anchor code* is the real highlight.
                Button {
                    onBroadcast()
                } label: {
                    Label("Broadcast Anchor", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Spacer()

                #if os(visionOS)
                if #available(visionOS 26.0, *) {
                    Button {
                        onStartShareSpace()
                    } label: {
                        Label("Share Space", systemImage: "shareplay")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

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
            }
        }
    }

    private struct ConnectionBadge: View {
        enum State { case offline, connected, shareplay }
        let state: State

        var body: some View {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundStyle(dotStyle)

                Image(systemName: icon)
                    .font(.caption)

                Text(label)
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(borderStyle, lineWidth: 1))
            .foregroundStyle(.primary)
        }

        private var label: String {
            switch state {
            case .offline: return "Offline"
            case .connected: return "Connected"
            case .shareplay: return "SharePlay"
            }
        }

        private var icon: String {
            switch state {
            case .offline: return "person.2"
            case .connected: return "person.2.fill"
            case .shareplay: return "shareplay"
            }
        }

        private var dotStyle: AnyShapeStyle {
            switch state {
            case .offline: return AnyShapeStyle(Color.secondary.opacity(0.7))
            case .connected: return AnyShapeStyle(Color.cyan)
            case .shareplay: return AnyShapeStyle(Color.green)
            }
        }

        private var borderStyle: Color {
            switch state {
            case .offline: return Color.secondary.opacity(0.35)
            case .connected: return Color.cyan.opacity(0.55)
            case .shareplay: return Color.green.opacity(0.55)
            }
        }
    }

    private struct AnchorCodeBadge: View {
        let code: String
        let isReady: Bool

        var body: some View {
            Text(code.uppercased())
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.bold)
                .tracking(1.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isReady ? Color.blue.opacity(0.75) : Color.secondary.opacity(0.35),
                        lineWidth: isReady ? 2 : 1
                    )
                )
                .shadow(color: isReady ? Color.blue.opacity(0.20) : .clear, radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Diagram chooser sheet

    private struct DiagramChooserSheet: View {
        let files: [String]
        @Binding var selectedFile: String
        @Environment(\.dismiss) private var dismiss

        @State private var query: String = ""

        private var filtered: [String] {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return files }
            return files.filter { $0.localizedCaseInsensitiveContains(q) }
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    List {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                selectedFile = name
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)

                                    Text(name)
                                        .lineLimit(1)

                                    Spacer()

                                    if name == selectedFile {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search.")
                        )
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                    }
                }
                .navigationTitle("Diagrams")
                .searchable(
                    text: $query,
                    placement: .toolbar,
                    prompt: "Search diagrams"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
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

// MARK: - Immersive View

struct VisionOSImmersiveView: View {
    @ObservedObject var sharedState: VisionOSAppState
    @ObservedObject var collaborativeSession: CollaborativeSessionManager
    let immersionStyle: ImmersionStyle
    @State private var showBackgroundOverlay = false
    @State private var savedPlaneViz: Bool? = nil

    var body: some View {
        ImmersiveSpaceWrapper(
            activeFiles: $sharedState.activeFiles,
            onClose: { file in
                sharedState.activeFiles.removeAll { $0 == file }
                sharedState.appModel.freeDiagramPosition(filename: file)
                collaborativeSession.removeDiagram(filename: file)
            },
            collaborativeSession: collaborativeSession,
            showBackgroundOverlay: showBackgroundOverlay
        )
        .environment(sharedState.appModel)
        .onAppear {
            showBackgroundOverlay = false
            if collaborativeSession.sharedAnchor == nil {
                collaborativeSession.broadcastCurrentSharedAnchor()
            }
        }
        .onReceive(collaborativeSession.$sharedDiagrams) { diagrams in
            guard collaborativeSession.isSharePlayActive else { return }

            let sharedFilenames = Set(diagrams.map { $0.filename })
            let currentFilenames = Set(sharedState.activeFiles)

            if collaborativeSession.isSharePlayHost {
                print("📊 SharePlay host: keeping \(currentFilenames.count) local diagrams (source of truth)")
                return
            }

            if sharedFilenames.isEmpty && !currentFilenames.isEmpty {
                print("⚠️ Client: sharedDiagrams is empty but we have \(currentFilenames.count) local diagrams - skipping removal")
                return
            }

            let diagramsToRemove = currentFilenames.subtracting(sharedFilenames)
            if !diagramsToRemove.isEmpty {
                sharedState.activeFiles.removeAll { diagramsToRemove.contains($0) }
                print("🗑️ Client: removed \(diagramsToRemove.count) diagrams no longer in shared list")
            }

            for diagram in diagrams {
                if !currentFilenames.contains(diagram.filename) {
                    Task { @MainActor in
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = .prettyPrinted

                            var diagramData: [String: Any] = [
                                "elements": diagram.elements.map { element -> [String: Any] in
                                    let elementData = try! encoder.encode(element)
                                    return try! JSONSerialization.jsonObject(with: elementData) as! [String: Any]
                                }
                            ]

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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding()
            } else {
                Label("Awaiting Shared Anchor", systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }
}

#endif

#if os(visionOS)
private extension VisionOSMainView {
    @available(visionOS 26.0, *)
    @MainActor
    func startSharePlayForImmersiveSpace() async {
        if !hasEnteredImmersive {
            let opened = await ensureImmersiveSpaceActive()
            if !opened {
                print("❌ Cannot start SharePlay: failed to open immersive space")
                return
            }
        }

        await shareExistingDiagrams()

        let activity = SharedSpaceActivity()
        _ = try? await activity.activate()
        print("✅ SharePlay activity activated for immersive space sharing")
    }

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

    @MainActor
    func ensureImmersiveSpaceActive() async -> Bool {
        if hasEnteredImmersive { return true }
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
