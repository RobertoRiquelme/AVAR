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

    // MARK: - Diagrams received over the network
    //
    // Held in memory rather than written to disk. The disk round-trip it replaces was broken in
    // three separate ways:
    //   1. it re-encoded elements under an `"elements"` key, forcing `is2D = false` and
    //      rebuilding every 2D RT/RS diagram as 3D on the receiver;
    //   2. it wrote a `"sharedPosition"` key that `ScriptOutput` has no CodingKey for, so the
    //      position was silently dropped;
    //   3. `ElementService.loadScriptOutput` checks `Bundle.main` FIRST, so for any bundled
    //      example filename the receiver loaded its own local copy and ignored what was sent.
    //
    // Checking this cache before the bundle makes (3) structurally impossible.
    //
    // `@MainActor` rather than a lock: every caller is already MainActor-isolated
    // (`ElementViewModel.loadData`, `ContentView.task`, `shareExistingDiagrams`), so the
    // compiler proves the isolation instead of us asserting it.
    @MainActor private static var receivedDiagrams: [String: ScriptOutput] = [:]

    @MainActor
    static func registerReceived(_ output: ScriptOutput, for filename: String) {
        receivedDiagrams[filename] = output
        if isVerboseLoggingEnabled {
            logger.debug("📥 Registered received diagram '\(filename, privacy: .public)' (\(output.elements.count, privacy: .public) elements, is2D=\(output.is2D, privacy: .public))")
        }
    }

    @MainActor
    static func forgetReceived(_ filename: String) {
        receivedDiagrams.removeValue(forKey: filename)
    }

    /// Whether this diagram arrived from a peer rather than being created on this device.
    ///
    /// This is the provenance signal used to decide who owns a diagram's pose. It cannot be
    /// inferred from "did we receive a transform for it", because `shareDiagram` appends our own
    /// diagrams to `sharedDiagrams` too — so the update handler fires for locally-created
    /// diagrams as well.
    @MainActor
    static func isReceived(_ filename: String) -> Bool {
        receivedDiagrams[filename] != nil
    }

    @MainActor
    static func loadScriptOutput(from filename: String) throws -> ScriptOutput {
        // Network-received data wins over anything on disk or in the bundle.
        if let received = receivedDiagrams[filename] {
            if isVerboseLoggingEnabled {
                logger.debug("📄 Using received diagram '\(filename, privacy: .public)' (\(received.elements.count, privacy: .public) elements, is2D=\(received.is2D, privacy: .public))")
            }
            return received
        }
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
