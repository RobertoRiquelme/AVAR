//
//  AVAR2App.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import QuartzCore

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

    // Gather all example files in the bundle (without extension)
    let files: [String]
    @State private var selectedFile: String
    @State private var hasEnteredImmersive: Bool = false
    /// List of diagrams currently loaded into the immersive space
    @State private var activeFiles: [String] = []
    @StateObject private var fpsMonitor = FPSMonitor()

    init() {
        // Find all .txt resources in the main bundle
        let names = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        self.files = names
        // Default to first file if available
        _selectedFile = State(initialValue: names.first ?? "")
    }

    var body: some Scene {
        // 1. 2D launcher
        WindowGroup {
            VStack(spacing: 20) {
                Text("Launch Immersive Experience")
                    .font(.title)
                    .padding(.top)

                // Picker to choose which example file to load
                Picker("Select Example", selection: $selectedFile) {
                    ForEach(files, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)

                // Enter or add diagrams to the immersive space
                Button(hasEnteredImmersive ? "Add Diagram" : "Enter Immersive Space") {
                    Task {
                        if !hasEnteredImmersive {
                            hasEnteredImmersive = true
                            await openImmersiveSpace(id: "MainImmersive")
                        }
                        activeFiles.append(selectedFile)
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
                    .padding(.bottom)
            }
            .padding()
            .contentShape(Rectangle())
        }

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            // Render all active diagrams in the same immersive space
            Group {
                ForEach(activeFiles, id: \.self) { file in
                    ContentView(filename: file) {
                        activeFiles.removeAll { $0 == file }
                    }
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
