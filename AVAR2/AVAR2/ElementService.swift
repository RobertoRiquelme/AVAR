//
//  ElementService.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation

enum ElementService {
    static func loadElements(from filename: String) throws -> [ElementDTO] {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "txt") else {
            throw NSError(domain: "Missing file", code: 404)
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ScriptOutput.self, from: data)
        return decoded.elements
    }
}
