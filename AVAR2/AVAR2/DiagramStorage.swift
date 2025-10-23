//
//  DiagramStorage.swift
//  AVAR2
//
//  Centralizes disk locations used for dynamically generated diagrams.
//

import Foundation

enum DiagramStorage {
    private static let folderName = "HTTPDiagrams"

    /// Returns the shared directory where dynamically generated diagrams are stored.
    /// The directory lives in the caches folder so it is accessible to every scene.
    static func sharedDirectory() throws -> URL {
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseDirectory.appendingPathComponent(folderName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    /// Returns the URL for a diagram file with the given filename and extension.
    static func fileURL(for filename: String, withExtension fileExtension: String) throws -> URL {
        try sharedDirectory()
            .appendingPathComponent(filename, isDirectory: false)
            .appendingPathExtension(fileExtension)
    }
}
