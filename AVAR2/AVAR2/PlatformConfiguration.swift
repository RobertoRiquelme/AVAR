import Foundation
import SwiftUI

/// Platform-specific configuration and helpers
enum PlatformConfiguration {
    
    /// Current platform identifier
    static var currentPlatform: Platform {
        #if os(visionOS)
        return .visionOS
        #elseif os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return .unknown
        #endif
    }
    
    /// Supported platform types
    enum Platform: String, CaseIterable {
        case visionOS = "visionOS"
        case iOS = "iOS"
        case macOS = "macOS"
        case unknown = "unknown"
        
        var displayName: String {
            switch self {
            case .visionOS: return "Apple Vision Pro"
            case .iOS: return "iPhone/iPad"
            case .macOS: return "Mac"
            case .unknown: return "Unknown Platform"
            }
        }
        
        var supportsAR: Bool {
            switch self {
            case .visionOS, .iOS: return true
            case .macOS, .unknown: return false
            }
        }
        
        var supportsImmersiveSpaces: Bool {
            switch self {
            case .visionOS: return true
            case .iOS, .macOS, .unknown: return false
            }
        }
        
        var icon: String {
            switch self {
            case .visionOS: return "visionpro"
            case .iOS: return "iphone"
            case .macOS: return "desktopcomputer"
            case .unknown: return "questionmark"
            }
        }
    }
    
    /// Platform-specific UI scaling factors
    static var uiScale: CGFloat {
        switch currentPlatform {
        case .visionOS: return 1.0
        case .iOS: return 0.9
        case .macOS: return 1.1
        case .unknown: return 1.0
        }
    }
    
    /// Platform-specific diagram scaling
    static var diagramScale: Float {
        switch currentPlatform {
        case .visionOS: return 1.0
        case .iOS: return 0.3  // Smaller diagrams for mobile viewing
        case .macOS: return 0.8
        case .unknown: return 1.0
        }
    }
    
    /// Maximum number of concurrent diagrams for platform
    static var maxConcurrentDiagrams: Int {
        switch currentPlatform {
        case .visionOS: return 10
        case .iOS: return 3  // Limited for performance
        case .macOS: return 5
        case .unknown: return 1
        }
    }
    
    /// Platform-specific networking configuration
    static var networkConfiguration: NetworkConfig {
        switch currentPlatform {
        case .visionOS:
            return NetworkConfig(
                preferredDiscoveryRange: .near,
                maxConnections: 8,
                connectionTimeout: 30.0
            )
        case .iOS:
            return NetworkConfig(
                preferredDiscoveryRange: .medium,
                maxConnections: 4,
                connectionTimeout: 15.0
            )
        case .macOS:
            return NetworkConfig(
                preferredDiscoveryRange: .far,
                maxConnections: 6,
                connectionTimeout: 45.0
            )
        case .unknown:
            return NetworkConfig(
                preferredDiscoveryRange: .medium,
                maxConnections: 2,
                connectionTimeout: 10.0
            )
        }
    }
    
    /// Check if current platform supports specific features
    static func supports(_ feature: Feature) -> Bool {
        switch feature {
        case .collaborativeSessions:
            return currentPlatform.supportsAR
        case .immersiveSpaces:
            return currentPlatform.supportsImmersiveSpaces
        case .arViewing:
            return currentPlatform.supportsAR
        case .httpServer:
            return true // All platforms support HTTP server
        case .fileImport:
            return true // All platforms support file import
        }
    }
    
    enum Feature {
        case collaborativeSessions
        case immersiveSpaces
        case arViewing
        case httpServer
        case fileImport
    }
}

struct NetworkConfig {
    let preferredDiscoveryRange: DiscoveryRange
    let maxConnections: Int
    let connectionTimeout: TimeInterval
    
    enum DiscoveryRange {
        case near, medium, far
    }
}

/// Platform-aware view modifier for consistent styling
struct PlatformAwareModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scaleEffect(PlatformConfiguration.uiScale)
            .animation(.easeInOut(duration: 0.2), value: PlatformConfiguration.uiScale)
    }
}

extension View {
    /// Apply platform-aware styling
    func platformAware() -> some View {
        modifier(PlatformAwareModifier())
    }
    
    /// Conditionally apply modifiers based on platform
    @ViewBuilder
    func ifPlatform<Content: View>(
        _ platform: PlatformConfiguration.Platform,
        transform: (Self) -> Content
    ) -> some View {
        if PlatformConfiguration.currentPlatform == platform {
            transform(self)
        } else {
            self
        }
    }
    
    /// Apply modifiers only if platform supports feature
    @ViewBuilder
    func ifSupports<Content: View>(
        _ feature: PlatformConfiguration.Feature,
        transform: (Self) -> Content
    ) -> some View {
        if PlatformConfiguration.supports(feature) {
            transform(self)
        } else {
            self
        }
    }
}