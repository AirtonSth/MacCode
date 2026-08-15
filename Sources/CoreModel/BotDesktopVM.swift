import Foundation

public enum BotDesktopVMRunState: String, Codable, Sendable, Equatable {
    case stopped
    case failed
    case running
}

public struct BotDesktopVMIdentity: Codable, Sendable, Equatable {
    public static let noGuestImageCode = "no-guest-image"
    public static let virtualizationUnsupportedCode = "virtualization-unsupported"
    public static let bootNotShippedCode = "boot-not-shipped"
    public static let bootFailedCode = "boot-failed"

    public var id: UUID
    public var botID: BotID
    public var generation: Int
    public var bundlePath: String
    public var state: BotDesktopVMRunState
    public var lastError: String?
    public var lastErrorDetail: String?
    public var virtualizationSupported: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        botID: BotID,
        generation: Int = 1,
        bundlePath: String,
        state: BotDesktopVMRunState = .stopped,
        lastError: String? = nil,
        lastErrorDetail: String? = nil,
        virtualizationSupported: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.generation = generation
        self.bundlePath = bundlePath
        self.state = state
        self.lastError = lastError
        self.lastErrorDetail = lastErrorDetail
        self.virtualizationSupported = virtualizationSupported
        self.updatedAt = updatedAt
    }

    public var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    public var statusPill: String {
        switch state {
        case .stopped:
            return "Local VM · stopped"
        case .failed:
            return "Local VM · failed"
        case .running:
            return "Local VM · running"
        }
    }

    public var honestyLabel: String {
        if state == .running {
            return "Running. Guest started via Virtualization.framework. Same Mac host; not isolated."
        }
        if lastError == Self.virtualizationUnsupportedCode {
            return "Stopped. Virtualization is not supported on this Mac. Work still uses this Mac account; not isolated."
        }
        if lastError == Self.noGuestImageCode {
            return "Stopped. No guest image. Work still uses this Mac account; not isolated."
        }
        if lastError == Self.bootFailedCode {
            let detail = (lastErrorDetail?.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Virtualization.framework rejected the guest image"
            return "Stopped. Boot failed: \(detail). Work still uses this Mac account; not isolated."
        }
        if lastError == Self.bootNotShippedCode {
            return "Stopped. Guest image present; boot is not shipped. Work still uses this Mac account; not isolated."
        }
        return "Stopped. Work still uses this Mac account; not isolated."
    }
}
