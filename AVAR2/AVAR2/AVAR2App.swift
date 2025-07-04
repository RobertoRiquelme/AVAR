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

                Button(hasEnteredImmersive ? "Add Diagram" : "Enter Immersive Space") {
                    Task {
                        if inputMode == .json && !isJSONValid {
                            return // Prevent invalid input
                        }

                        if !hasEnteredImmersive {
                            hasEnteredImmersive = true
                            await openImmersiveSpace(id: "MainImmersive")
                        }

                        let newFile = inputMode == .file ? selectedFile : "input_json_\(UUID().uuidString)"
                        if inputMode == .json {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(newFile).appendingPathExtension("txt")
                            try? jsonInput.write(to: tempURL, atomically: true, encoding: .utf8)
                        }
                        activeFiles.append(newFile)

                        // Optional: Save jsonInput to temp file here if needed
                    }
                }
                .font(.title2)

                if hasEnteredImmersive {
                    Button("Exit Immersive Space") {
                        Task {
                            await dismissImmersiveSpace()
                            hasEnteredImmersive = false
                            activeFiles.removeAll()
                        }
                    }
                    .font(.title2)
                }

                Spacer()
                Text("\(fpsMonitor.fps) FPS")
                    .font(.title)
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
        }

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            Group {
                ForEach(activeFiles, id: \.self) { file in
                    ContentView(filename: file) {
                        activeFiles.removeAll { $0 == file }
                    }
                }
            }
            .environment(appModel)
            .task {
                await appModel.startSurfaceDetectionIfNeeded()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
