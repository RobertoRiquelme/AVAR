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

/// Static surface detection view that never changes
struct StaticSurfaceView: View {
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        RealityView { content in
            content.add(appModel.surfaceDetector.rootEntity)
        }
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

                Spacer()
                Text("\(fpsMonitor.fps) FPS")
                    .font(.title)
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
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
            ZStack {
                // Static surface detection layer - completely independent
                StaticSurfaceView()
                    .environment(appModel)
                
                // Dynamic diagrams layer - updates when activeFiles changes
                Group {
                    ForEach(activeFiles, id: \.self) { file in
                        ContentView(filename: file) {
                            activeFiles.removeAll { $0 == file }
                        }
                    }
                }
                .environment(appModel)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
