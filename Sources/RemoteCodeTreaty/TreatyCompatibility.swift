import Foundation

public struct TreatyVersion: Codable, Equatable, Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: TreatyVersion, rhs: TreatyVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public struct TreatyCompatibility: Codable, Equatable, Sendable {
    public enum Evaluation: Equatable, Sendable {
        case compatibleLegacyV0
        case compatible(TreatyVersion)
        case updateRequired
    }

    public static let v1 = TreatyCompatibility(
        current: TreatyVersion(major: 1, minor: 0),
        supportedMajors: [0, 1]
    )

    public let current: TreatyVersion
    public let supportedMajors: [Int]

    public init(current: TreatyVersion, supportedMajors: [Int]) {
        self.current = current
        self.supportedMajors = supportedMajors
    }

    private enum CodingKeys: String, CodingKey {
        case current
        case supportedMajors = "supported_majors"
    }

    public func supports(major: Int, minimumMinor: Int = 0) -> Bool {
        supportedMajors.contains(major)
            && (current.major != major || current.minor >= minimumMinor)
    }

    public static func evaluate(
        host: TreatyCompatibility?,
        client: TreatyVersion = TreatyVersion(major: 1, minor: 0)
    ) -> Evaluation {
        guard let host else { return .compatibleLegacyV0 }
        guard host.supportedMajors.contains(client.major) else {
            return .updateRequired
        }
        return .compatible(host.current)
    }
}
