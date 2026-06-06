import CryptoKit
import Foundation
import CoreModel

public struct AgentSkillManifest: Codable, Sendable, Equatable {
    public let provider: AgentProvider
    public let skillID: String
    public let sourceURL: String
    public let sourceRevision: String
    public let localVersion: String
    public let sha256: String
    public let installPath: String
    public let installedAt: Date

    public init(
        provider: AgentProvider,
        skillID: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        sha256: String,
        installPath: String,
        installedAt: Date
    ) {
        self.provider = provider
        self.skillID = skillID
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.localVersion = localVersion
        self.sha256 = sha256
        self.installPath = installPath
        self.installedAt = installedAt
    }
}

public struct AgentSkillInstallResult: Sendable, Equatable {
    public enum Action: String, Sendable {
        case installed
        case skipped
    }

    public let action: Action
    public let manifest: AgentSkillManifest
}

public final class AgentSkillInstaller: @unchecked Sendable {
    public static let distillSkillID = "distill"
    public static let distillSourceURL = "https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"
    public static let distillLocalVersion = "1"

    public static let distillSkillTemplate = """
    ---
    name: distill
    description: Conversation mode that makes the LLM speak in distill compressed language for the whole thread.
    source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    ---

    # Distill

    Use when RemoteCode invokes `/distill` or asks the provider to use Token Saver / Distill language.

    This is a conversation style mode, not a prompt-compression request.
    Do not return the user's prompt compressed as an artifact.
    Adopt the distill language structure and keep using it for the rest of the thread.

    Core behavior:
    - English only unless the user explicitly requests another language.
    - Military English + AR-0/AR-1 baseline.
    - Short command lines.
    - Fixed semantic prefixes: S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof.
    - Semantic atoms over natural phrases.
    - One idea per line.
    - Explicit constraints and pass criteria.
    - Exact paths, commands, env vars, IDs when useful.
    - No filler.
    - No cryptic code.
    - No long prose unless the user asks for explanation.
    - Keep hidden chain-of-thought private.

    Thread behavior:
    - Use distill structure for status updates, plans, summaries, reviews, and final answers.
    - Do not output a rewritten/compressed version of the latest user prompt unless the user explicitly asks to compress text.
    - Emit `Dict:` early when aliases or prefixes matter.

    Source reference:
    - https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md
    """

    private let appSupportDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(appSupportDirectory: URL, fileManager: FileManager = .default) {
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func installDistillSkill(
        for provider: AgentProvider,
        sourceRevision: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        try installSkill(
            provider: provider,
            skillID: Self.distillSkillID,
            skillText: Self.distillSkillTemplate,
            sourceURL: Self.distillSourceURL,
            sourceRevision: sourceRevision,
            localVersion: Self.distillLocalVersion,
            installedAt: installedAt
        )
    }

    public func installSkill(
        provider: AgentProvider,
        skillID: String,
        skillText: String,
        sourceURL: String,
        sourceRevision: String,
        localVersion: String,
        installedAt: Date = Date()
    ) throws -> AgentSkillInstallResult {
        let directory = skillDirectory(provider: provider, skillID: skillID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let skillURL = directory.appendingPathComponent("SKILL.md")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = Data(skillText.utf8)
        let checksum = Self.sha256Hex(data)
        let manifest = AgentSkillManifest(
            provider: provider,
            skillID: skillID,
            sourceURL: sourceURL,
            sourceRevision: sourceRevision,
            localVersion: localVersion,
            sha256: checksum,
            installPath: skillURL.path,
            installedAt: installedAt
        )

        if let existingData = try? Data(contentsOf: skillURL),
           Self.sha256Hex(existingData) == checksum,
           let manifestData = try? Data(contentsOf: manifestURL),
           let existingManifest = try? decoder.decode(AgentSkillManifest.self, from: manifestData),
           existingManifest.sourceRevision == sourceRevision,
           existingManifest.localVersion == localVersion {
            return AgentSkillInstallResult(action: .skipped, manifest: existingManifest)
        }

        try data.write(to: skillURL, options: .atomic)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return AgentSkillInstallResult(action: .installed, manifest: manifest)
    }

    public func skillDirectory(provider: AgentProvider, skillID: String) -> URL {
        appSupportDirectory
            .appendingPathComponent("AgentSkills", isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(skillID, isDirectory: true)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
