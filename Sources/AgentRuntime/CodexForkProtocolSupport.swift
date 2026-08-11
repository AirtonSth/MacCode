import Foundation

/// Result of proving the installed Codex app-server contract needed for a
/// recoverable native fork. `thread/fork` alone is insufficient: RemoteCode
/// also needs an opaque client marker, paged discovery, parent attribution,
/// and deletion for compensation after a partial local failure.
public struct CodexForkProtocolSupport: Sendable, Equatable {
    public let isSupported: Bool
    public let reason: String

    public static let unsupported = CodexForkProtocolSupport(
        isSupported: false,
        reason: "Codex fork protocol has not been proven for this binary."
    )

    public init(isSupported: Bool, reason: String) {
        self.isSupported = isSupported
        self.reason = reason
    }

    /// Generates the schema from the exact executable that will own the
    /// session. Results are cached by resolved path + file identity so replacing
    /// a binary at the same path forces a fresh fail-closed probe.
    public static func probe(
        binary: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 3
    ) -> CodexForkProtocolSupport {
        guard let resolved = ProcessLocator.resolve(binary) else {
            return CodexForkProtocolSupport(isSupported: false, reason: "Codex binary is unavailable.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        let key = ProbeKey(
            path: resolved,
            size: attributes?[.size] as? UInt64 ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date ?? .distantPast
        )
        if let cached = ProbeCache.shared.value(for: key) {
            return cached
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-codex-fork-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            let result = CodexForkProtocolSupport(
                isSupported: false,
                reason: "Codex schema probe directory could not be created: \(error)"
            )
            ProbeCache.shared.store(result, for: key)
            return result
        }

        guard let command = ProviderCLIProbe.run(
            binaryPath: resolved,
            arguments: ["app-server", "generate-json-schema", "--experimental", "--out", directory.path],
            environment: environment,
            timeoutSeconds: timeout
        ), command.status == 0 else {
            let result = CodexForkProtocolSupport(
                isSupported: false,
                reason: "Codex did not produce its app-server schema within the probe deadline."
            )
            ProbeCache.shared.store(result, for: key)
            return result
        }

        let result = inspect(schemaDirectory: directory)
        ProbeCache.shared.store(result, for: key)
        return result
    }

    public static func inspect(schemaDirectory: URL) -> CodexForkProtocolSupport {
        do {
            let clientRequest = try object(at: schemaDirectory.appendingPathComponent("ClientRequest.json"))
            let forkParams = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadForkParams.json"))
            let forkResponse = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadForkResponse.json"))
            let listParams = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadListParams.json"))
            let listResponse = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadListResponse.json"))
            let deleteParams = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadDeleteParams.json"))
            let deleteResponse = try object(at: schemaDirectory.appendingPathComponent("v2/ThreadDeleteResponse.json"))

            let methods = Set((clientRequest["oneOf"] as? [[String: Any]] ?? []).compactMap { variant in
                let properties = variant["properties"] as? [String: Any]
                let method = properties?["method"] as? [String: Any]
                return (method?["enum"] as? [String])?.first
            })
            guard methods.isSuperset(of: ["thread/fork", "thread/list", "thread/delete"]) else {
                return unsupported("required thread/fork, thread/list, or thread/delete method is absent")
            }

            guard required(forkParams).contains("threadId"),
                  let forkProperties = forkParams["properties"] as? [String: Any],
                  allowsString(forkProperties["threadId"], definitions: definitions(forkParams)),
                  allowsString(forkProperties["threadSource"], definitions: definitions(forkParams)) else {
                return unsupported("ThreadForkParams lacks string threadId/threadSource")
            }
            guard required(forkResponse).contains("thread"),
                  validatesThreadProjection(in: forkResponse) else {
                return unsupported("ThreadForkResponse lacks verifiable fork identity fields")
            }

            guard let listParamProperties = listParams["properties"] as? [String: Any],
                  allowsString(listParamProperties["cursor"], definitions: definitions(listParams)),
                  allowsBoolean(listParamProperties["archived"]) else {
                return unsupported("ThreadListParams lacks cursor/archived reconciliation fields")
            }
            guard required(listResponse).contains("data"),
                  let listProperties = listResponse["properties"] as? [String: Any],
                  let dataSchema = listProperties["data"] as? [String: Any],
                  dataSchema["type"] as? String == "array",
                  allowsString(listProperties["nextCursor"], definitions: definitions(listResponse)),
                  validatesThreadProjection(in: listResponse) else {
                return unsupported("ThreadListResponse lacks paged fork identity fields")
            }

            guard required(deleteParams).contains("threadId"),
                  let deleteProperties = deleteParams["properties"] as? [String: Any],
                  allowsString(deleteProperties["threadId"], definitions: definitions(deleteParams)),
                  deleteResponse["type"] as? String == "object" else {
                return unsupported("ThreadDelete contract is absent or incompatible")
            }
            return CodexForkProtocolSupport(isSupported: true, reason: "Codex fork reconciliation schema is complete.")
        } catch {
            return unsupported("schema inspection failed: \(error)")
        }
    }

    private static func validatesThreadProjection(in document: [String: Any]) -> Bool {
        let allDefinitions = definitions(document)
        guard let thread = allDefinitions["Thread"] as? [String: Any],
              let properties = thread["properties"] as? [String: Any],
              required(thread).isSuperset(of: ["id", "createdAt"]),
              allowsString(properties["id"], definitions: allDefinitions),
              allowsString(properties["forkedFromId"], definitions: allDefinitions),
              allowsString(properties["threadSource"], definitions: allDefinitions),
              allowsInteger(properties["createdAt"]) else {
            return false
        }
        return true
    }

    private static func object(at url: URL) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else {
            throw SchemaInspectionError.notObject(url.lastPathComponent)
        }
        return object
    }

    private static func definitions(_ object: [String: Any]) -> [String: Any] {
        object["definitions"] as? [String: Any] ?? [:]
    }

    private static func required(_ object: [String: Any]) -> Set<String> {
        Set(object["required"] as? [String] ?? [])
    }

    private static func allowsString(_ value: Any?, definitions: [String: Any]) -> Bool {
        guard let schema = value as? [String: Any] else { return false }
        if schema["type"] as? String == "string" { return true }
        if (schema["type"] as? [String])?.contains("string") == true { return true }
        if let reference = schema["$ref"] as? String,
           let name = reference.split(separator: "/").last.map(String.init),
           let target = definitions[name] {
            return allowsString(target, definitions: definitions)
        }
        return (schema["anyOf"] as? [Any] ?? []).contains {
            allowsString($0, definitions: definitions)
        }
    }

    private static func allowsBoolean(_ value: Any?) -> Bool {
        guard let schema = value as? [String: Any] else { return false }
        if schema["type"] as? String == "boolean" { return true }
        return (schema["type"] as? [String])?.contains("boolean") == true
    }

    private static func allowsInteger(_ value: Any?) -> Bool {
        guard let schema = value as? [String: Any] else { return false }
        if schema["type"] as? String == "integer" { return true }
        return (schema["type"] as? [String])?.contains("integer") == true
    }

    private static func unsupported(_ reason: String) -> CodexForkProtocolSupport {
        CodexForkProtocolSupport(isSupported: false, reason: reason)
    }

    private enum SchemaInspectionError: Error {
        case notObject(String)
    }

    private struct ProbeKey: Hashable {
        let path: String
        let size: UInt64
        let modificationDate: Date
    }

    /// Peak distinct Codex binary identities retained in the fork-protocol
    /// probe cache. Binary path churn would otherwise pin unbounded reason
    /// strings process-wide; 32 matches catalog/discovery cache order.
    public static let probeCacheCountLimit = 32

    /// Pure insert/evict for probe-cache style maps (unit tests). Keeps `key`;
    /// drops arbitrary other keys when over `countLimit`.
    public static func noteProbeCacheEntry<Key: Hashable>(
        _ values: inout [Key: CodexForkProtocolSupport],
        key: Key,
        value: CodexForkProtocolSupport,
        countLimit: Int = probeCacheCountLimit
    ) {
        values[key] = value
        let cap = max(1, countLimit)
        while values.count > cap {
            if let victim = values.keys.first(where: { $0 != key }) ?? values.keys.first {
                values.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }

    private final class ProbeCache: @unchecked Sendable {
        static let shared = ProbeCache()
        private let lock = NSLock()
        private var values: [ProbeKey: CodexForkProtocolSupport] = [:]

        func value(for key: ProbeKey) -> CodexForkProtocolSupport? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: CodexForkProtocolSupport, for key: ProbeKey) {
            lock.lock(); defer { lock.unlock() }
            CodexForkProtocolSupport.noteProbeCacheEntry(
                &values, key: key, value: value
            )
        }
    }
}
