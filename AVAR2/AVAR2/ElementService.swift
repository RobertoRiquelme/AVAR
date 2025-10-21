//
//  ElementService.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation
import OSLog

enum ElementService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ElementService")
    private static let isVerboseLoggingEnabled = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil
    /// Loads elements from a JSON or TXT file in the main bundle.
    static func loadElements(from filename: String) throws -> [ElementDTO] {
        // Try common extensions
        let exts = ["json", "txt"]
        var fileURL: URL?
        for ext in exts {
            if let url = Bundle.main.url(forResource: filename, withExtension: ext) {
                fileURL = url
                break
            }
        }
        guard let url = fileURL else {
            throw NSError(domain: "ElementService", code: 404, userInfo: [NSLocalizedDescriptionKey: "File '\(filename)' not found"])
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ScriptOutput.self, from: data)
        return decoded.elements
    }

    /// Loads the full `ScriptOutput`, including its `is2D` flag.
    static func loadScriptOutput(from filename: String) throws -> ScriptOutput {
        // Try common extensions
        let exts = ["json", "txt"]
        var fileURL: URL?

        for ext in exts {
            if let url = Bundle.main.url(forResource: filename, withExtension: ext) {
                fileURL = url
                break
            }
        }

        // If not found in bundle, check shared diagram storage (HTTP uploads)
        if fileURL == nil {
            if let storageDirectory = try? DiagramStorage.sharedDirectory() {
                for ext in exts {
                    let storedURL = storageDirectory
                        .appendingPathComponent(filename)
                        .appendingPathExtension(ext)
                    if FileManager.default.fileExists(atPath: storedURL.path) {
                        fileURL = storedURL
                        break
                    }
                }
            }
        }

        // Legacy fallback: check the temporary directory
        if fileURL == nil {
            for ext in exts {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    fileURL = tempURL
                    break
                }
            }
        }

        guard let url = fileURL else {
            throw NSError(domain: "ElementService", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "File '\(filename)' not found"])
        }

        let data = try Data(contentsOf: url)
        if isVerboseLoggingEnabled {
            logger.debug("📄 Loading JSON file: \(filename, privacy: .public) (\(data.count, privacy: .public) bytes)")
        }
        let decoded = try JSONDecoder().decode(ScriptOutput.self, from: data)
        if isVerboseLoggingEnabled {
            logger.debug("📋 Decoded \(decoded.elements.count, privacy: .public) elements, is2D: \(decoded.is2D, privacy: .public)")
            for (index, element) in decoded.elements.enumerated() {
                logger.debug("   Element \(index, privacy: .public): id=\(element.id ?? "nil", privacy: .public), type='\(element.type, privacy: .public)', hasShape=\(element.shape != nil, privacy: .public)")
                if let shape = element.shape {
                    logger.debug("      Shape: desc='\(shape.shapeDescription ?? "nil", privacy: .public)', extent=\(shape.extent ?? [], privacy: .public)")
                }
            }
        }
        return decoded
    }
}
