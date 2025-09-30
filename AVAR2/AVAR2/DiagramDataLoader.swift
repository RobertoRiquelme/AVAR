//
//  DiagramDataLoader.swift
//  AVAR2
//
//  Provides consistent error handling and logging for diagram loading.
//

import Foundation
import OSLog

enum DiagramLoadingError: LocalizedError {
    case fileMissing(String)
    case decodingFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let filename):
            return "The diagram file '\(filename)' could not be found."
        case .decodingFailed(let filename, let underlying):
            return "The diagram file '\(filename)' is invalid: \(underlying.localizedDescription)"
        }
    }
}

struct DiagramDataLoader {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "DiagramDataLoader")
    private static let isVerboseLoggingEnabled = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil

    static func loadScriptOutput(from filename: String) throws -> ScriptOutput {
        do {
            let output = try ElementService.loadScriptOutput(from: filename)
            if isVerboseLoggingEnabled {
                logger.debug("📄 Loaded diagram '\(filename, privacy: .public)' with \(output.elements.count, privacy: .public) elements")
            }
            return output
        } catch let error as NSError where error.domain == "ElementService" && error.code == 404 {
            logger.error("❌ Missing diagram file '\(filename, privacy: .public)'")
            throw DiagramLoadingError.fileMissing(filename)
        } catch let decodingError as DecodingError {
            logger.error("❌ Failed to decode diagram '\(filename, privacy: .public)': \(String(describing: decodingError), privacy: .public)")
            throw DiagramLoadingError.decodingFailed(filename, underlying: decodingError)
        } catch {
            logger.error("❌ Unexpected error loading diagram '\(filename, privacy: .public)': \(String(describing: error), privacy: .public)")
            throw DiagramLoadingError.decodingFailed(filename, underlying: error)
        }
    }
}
