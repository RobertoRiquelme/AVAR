//
//  AVAR2App.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI

@main
struct AVAR2: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    // Gather all example files in the bundle (without extension)
    let files: [String]
    @State private var selectedFile: String
    @State private var hasEnteredImmersive: Bool = false

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

                // Load immersive content with the currently selected example
                Button("Load Immersive Space") {
                    Task {
                        if(!hasEnteredImmersive){
                            hasEnteredImmersive = true
                        } else {
                            await dismissImmersiveSpace()
                        }
                        await openImmersiveSpace(id: "MainImmersive")
                    }
                }
                .font(.title2)

                Spacer()
            }
            .padding()
        }

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            // Pass selected file to ContentView
            ContentView(filename: selectedFile)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
