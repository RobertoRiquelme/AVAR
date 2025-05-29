//
//  ElementService.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation

enum ElementService {
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
        guard let url = fileURL else {
            throw NSError(domain: "ElementService", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "File '\(filename)' not found"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ScriptOutput.self, from: data)
    }
}
