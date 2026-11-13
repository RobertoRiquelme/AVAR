//
//  PlatformApp.swift
//  AVAR2
//

import SwiftUI
import simd
#if canImport(GroupActivities)
import GroupActivities
#endif

#if os(visionOS)
import RealityKit
import RealityKitContent
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Shared state for visionOS app
@MainActor
class VisionOSAppState: ObservableObject {
    @Published var activeFiles: [String] = []
    @Published var appModel = AppModel()

    func closeDiagram(_ filename: String) {
        activeFiles.removeAll { $0 == filename }
        appModel.freeDiagramPosition(filename: filename)
        DiagramDataLoader.forgetReceived(filename)
    }
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

            CollaborationCard(
                session: collaborativeSession,
                openCompanionConnection: { showingCollaborativeSession = true }
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
                                Task { @MainActor in
                                    if inputMode == .json && !isJSONValid { return }

                                    if !hasEnteredImmersive {
                                        let result = await openImmersiveSpace(id: "MainImmersive")
                                        switch result {
                                        case .opened:
                                            hasEnteredImmersive = true
                                        case .userCancelled, .error:
                                            print("❌ Failed to open immersive space for diagram")
                                            return
                                        @unknown default:
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

                                    if !sharedState.activeFiles.contains(newFile) {
                                        sharedState.activeFiles.append(newFile)
                                    }

                                    sharedState.appModel.showPlaneVisualization = false
                                    sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
                                }
                            } label: {
                                Label("Add Diagram", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isAddDiagramDisabled)

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
        .groupBoxStyle(RoundedCardGroupBoxStyle())
        .padding()
        .contentShape(Rectangle())
        .environment(sharedState.appModel)
        .sheet(isPresented: $showingCollaborativeSession) {
            CollaborativeSessionView(sessionManager: collaborativeSession)
        }
        .onChange(of: collaborativeSession.companionMode) { _, mode in
            if mode == .advertising { shareExistingDiagrams() }
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
                            let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for diagram update")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)
                                print("🔄 Redrawing diagram with ID: \(diagramId)")
                                self.sharedState.closeDiagram(existingInfo.filename)
                                self.collaborativeSession.removeDiagram(filename: existingInfo.filename)
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
                            let newFile = "http_diagram_\(diagramId)_\(Date().timeIntervalSince1970)"

                            do {
                                guard let data = rawJSON.data(using: .utf8) else {
                                    print("❌ Failed to convert raw JSON to data for diagram update")
                                    return
                                }
                                let tempURL = try DiagramStorage.fileURL(for: newFile, withExtension: "txt")
                                try data.write(to: tempURL)

                                print("🔄 Redrawing diagram with ID: \(diagramId)")
                                sharedState.closeDiagram(existingInfo.filename)
                                collaborativeSession.removeDiagram(filename: existingInfo.filename)
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
        .background {
            ShareLink(item: SharedSpaceActivity(), preview: SharePreview("AVAR2 Shared Space"))
                .hidden()
        }
        .onChange(of: collaborativeSession.isSharePlayActive, initial: true) { _, isActive in
            guard isActive else { return }
            sharedState.appModel.showPlaneVisualization = false
            sharedState.appModel.surfaceDetector.setVisualizationVisible(false)
            shareExistingDiagrams()
            Task { @MainActor in _ = await ensureImmersiveSpaceActive() }
        }
        // The launcher stays mounted while the immersive space opens or closes.
        .onReceive(collaborativeSession.$sharedDiagrams) { diagrams in
            for diagram in diagrams where !collaborativeSession.isLocallyShared(diagram) {
                DiagramDataLoader.registerReceived(
                    ScriptOutput(elements: diagram.elements, is2D: diagram.is2D),
                    for: diagram.filename
                )
                if !sharedState.activeFiles.contains(diagram.filename) {
                    sharedState.activeFiles.append(diagram.filename)
                    Task { @MainActor in _ = await ensureImmersiveSpaceActive() }
                }
            }
        }
        .onReceive(collaborativeSession.receivedDiagramRemoval) { filename in
            sharedState.closeDiagram(filename)
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

    private var isAddDiagramDisabled: Bool {
        (inputMode == .file && selectedFile.isEmpty) || (inputMode == .json && !isJSONValid)
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

    private struct CollaborationCard: View {
        @ObservedObject var session: CollaborativeSessionManager
        let openCompanionConnection: () -> Void

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if session.isSharePlayActive {
                        let status = session.alignmentDiagnostic
                        HStack {
                            Label(status.label, systemImage: status.isHealthy ? "checkmark.circle.fill" : "person.2")
                                .foregroundStyle(status.color)
                                .accessibilityLabel("SharePlay alignment: \(status.label)")
                            Spacer()
                            Button("Leave SharePlay") { session.stopSharePlay() }
                                .buttonStyle(.bordered)
                        }
                        Text(status.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if session.canRealign || session.isRealigning {
                            Button {
                                session.requestRealignment()
                            } label: {
                                Label(session.isRealigning ? "Realigning…" : "Realign Space",
                                      systemImage: "arrow.trianglehead.clockwise.rotate.90")
                            }
                            .buttonStyle(.bordered)
                            .disabled(session.isRealigning)
                        }
                        if let result = session.realignmentStatus {
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task { await session.startSharePlay() }
                        } label: {
                            Label(session.isStartingSharePlay ? "Opening SharePlay…" : "Invite Nearby Vision Pro",
                                  systemImage: "shareplay")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isStartingSharePlay)

                        Text("On one Vision Pro, choose the other person under Share with Nearby People. On the second Vision Pro, tap Join in the invitation.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let error = session.sharePlayStartError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        DisclosureGroup("Can’t find the invitation?") {
                            Text("On the second Vision Pro, open Control Center → Share Windows. If nearby people don’t appear, check Settings → General → Share Windows → Allow Nearby People.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Button(action: openCompanionConnection) {
                        Label("iPhone Companion", systemImage: "iphone")
                    }
                    .buttonStyle(.bordered)

                    DisclosureGroup("Diagnostics") {
                        if session.canRealign {
                            Button("Replace Shared Anchor") {
                                session.requestRealignment(replaceAnchor: true)
                            }
                            .disabled(session.isRealigning)
                            Text("Use this if the two origin markers appear in different places.")
                                .foregroundStyle(.secondary)
                        }
                        CollabDiagnosticsView(session: session)
                            .frame(maxHeight: 420)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Collaboration", systemImage: "person.2.wave.2")
            }
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
#endif

// NOTE: `broadcastSharedAnchor()` was deleted along with
// `CollaborativeSessionManager.broadcastCurrentSharedAnchor()`. It put a head pose (in
// practice the identity matrix) on the wire as a "shared anchor", which is the opposite of
// establishing alignment.

// MARK: - Immersive View

#if os(visionOS)
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
                sharedState.closeDiagram(file)
                collaborativeSession.removeDiagram(filename: file)
            },
            collaborativeSession: collaborativeSession,
            showBackgroundOverlay: showBackgroundOverlay
        )
        .environment(sharedState.appModel)
        .onAppear {
            showBackgroundOverlay = false
            // Deliberately no anchor broadcast here. The shared world anchor is created by the
            // elected owner once SharePlay reports nearby participants, and every device
            // resolves its transform locally from its own ARKit anchorUpdates.
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
        // Deliberately only three items. A wall of text is unreadable while wearing a headset
        // and standing next to someone else wearing one — the full panel lives in the launcher
        // window (CollabDiagnosticsView).
        .overlay(alignment: .topTrailing) {
            if collaborativeSession.isSessionActive || collaborativeSession.isSharePlayActive {
                HStack(spacing: 12) {
                    dot(collaborativeSession.sessionOriginIsTracked,
                        label: collaborativeSession.sharedAnchor
                            .map { String($0.id.prefix(6)) } ?? "no origin")
                    dot(collaborativeSession.hasNearbyParticipants, label: "nearby")
                    if collaborativeSession.sharedDiagrams.contains(where: {
                        collaborativeSession.requiresSharedOrigin(for: $0) &&
                        !$0.hasPose(relativeTo: collaborativeSession.currentPoseAnchorID)
                    }) {
                        Text("Waiting for diagram alignment")
                            .font(.caption2)
                    } else {
                        Text("\(sharedState.activeFiles.count) diagrams")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
            }
        }
    }

    private func dot(_ ok: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

// NOTE: `setupSharedAnchorCallbacks()` was an empty stub whose body was three comments saying
// the anchor transform "can be used to position content" — it never did anything. Stage 4
// replaces it properly by driving a `worldRoot` entity from the resolved anchor transform.
// `createSharedAnchorForDiagram` and `diagramAnchorMap` were written but never read.

#endif

#if os(visionOS)
private extension VisionOSMainView {
    @MainActor
    func shareExistingDiagrams() {
        for filename in sharedState.activeFiles where !DiagramDataLoader.isReceived(filename) {
            guard let cached = collaborativeSession.cachedTransform(for: filename) else { continue }
            do {
                let output = try DiagramDataLoader.loadScriptOutput(from: filename)
                collaborativeSession.shareDiagram(
                    filename: filename,
                    elements: output.elements,
                    is2D: output.is2D,
                    anchorRelativePosition: cached.position,
                    anchorRelativeOrientation: cached.orientation,
                    anchorRelativeScale: cached.scale,
                    poseAnchorID: cached.anchorID
                )
                print("📤 Shared diagram: \(filename)")
            } catch {
                print("❌ Failed to share existing diagram '\(filename)': \(error)")
            }
        }
    }

    @MainActor
    func ensureImmersiveSpaceActive() async -> Bool {
        if hasEnteredImmersive { return true }
        let result = await openImmersiveSpace(id: "MainImmersive")
        switch result {
        case .opened:
            hasEnteredImmersive = true
            return true
        case .userCancelled, .error:
            print("❌ Failed to open immersive space")
            hasEnteredImmersive = false
            return false
        @unknown default:
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
