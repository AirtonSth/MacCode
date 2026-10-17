import CoreModel
import Darwin
import Foundation
import Persistence
import XCTest
@testable import AppShell

final class BotContextRuntimeCostDockerTests: XCTestCase {
    private struct Runtime {
        let variant: String
        let support: URL
        let storageID: BotID
        let binding: BotContextBinding?
        let service: BotComputerGuestService
        var name: String { BotComputerGuestSpec.containerName(botID: storageID) }
        var network: String { BotComputerGuestSpec.networkName(botID: storageID) }
        var home: URL { BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: storageID) }
    }

    private struct Sample: Codable {
        let variant: String
        let phase: String
        let index: Int
        let readinessMilliseconds: Double
        let cpuPercent: Double
        let memoryUsage: String
        let pids: Int
        let writableLayerBytes: Int64
        let homeApparentBytes: Int64
        let resumed: Bool
    }

    private func homeBytes(_ home: URL) throws -> Int64 {
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: home,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let file as URL in entries {
            count += 1
            guard count <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                bytes += Int64(try XCTUnwrap(values.fileSize))
            }
        }
        if let enumerationError { throw enumerationError }
        return bytes
    }

    private func sample(_ runtime: Runtime, index: Int, cold: Bool, docker: BotComputerDockerCLI) throws -> Sample {
        if !cold {
            if let binding = runtime.binding {
                try runtime.service.stopForContextRecovery(identity: BotContextRuntimeIdentity(binding: binding))
            } else {
                try runtime.service.stop(botID: runtime.storageID)
            }
            XCTAssertFalse(try docker.inspect(name: runtime.name).running)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let ready: BotComputerGuestReady
        if let binding = runtime.binding {
            ready = try runtime.service.provision(contextBinding: binding, workspace: nil, registeredWorkspaces: [])
        } else {
            ready = try runtime.service.provision(botID: runtime.storageID)
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(ready.resumed, !cold)
        XCTAssertEqual(Array(ready.capturedPNG.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], "readiness must include an actual desktop frame")
        XCTAssertTrue(try docker.inspect(name: runtime.name).running)
        let rawStats = try docker.run(["stats", "--no-stream", "--format", "{{json .}}", runtime.name])
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: rawStats) as? [String: Any])
        let cpuText = try XCTUnwrap(stats["CPUPerc"] as? String)
        let cpu = try XCTUnwrap(Double(cpuText.replacingOccurrences(of: "%", with: "")))
        let memory = try XCTUnwrap(stats["MemUsage"] as? String)
        let pids = try XCTUnwrap(Int(try XCTUnwrap(stats["PIDs"] as? String)))
        let rawSize = try docker.run(["inspect", "--size", "--format", "{{.SizeRw}}", runtime.name])
        let layerBytes = try XCTUnwrap(Int64(String(decoding: rawSize, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(milliseconds.isFinite && milliseconds > 0)
        XCTAssertTrue(cpu.isFinite && cpu >= 0)
        XCTAssertGreaterThan(pids, 0)
        XCTAssertFalse(memory.isEmpty || memory.contains("--"))
        XCTAssertGreaterThanOrEqual(layerBytes, 0)
        XCTAssertTrue(try docker.inspect(name: runtime.name).running)
        return Sample(variant: runtime.variant, phase: cold ? "new_owned_scope_cached_image" : "stopped_container_resume",
            index: index, readinessMilliseconds: milliseconds, cpuPercent: cpu, memoryUsage: memory,
            pids: pids, writableLayerBytes: layerBytes, homeApparentBytes: try homeBytes(runtime.home), resumed: ready.resumed)
    }

    private func removeOwned(_ runtime: Runtime, docker: BotComputerDockerCLI) throws {
        if try docker.containerExists(name: runtime.name) {
            let data = try docker.run(["inspect", runtime.name])
            let object = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
            let config = try XCTUnwrap(object["Config"] as? [String: Any])
            let labels = try XCTUnwrap(config["Labels"] as? [String: String])
            let mounts = try XCTUnwrap(object["Mounts"] as? [[String: Any]])
            guard labels[BotComputerGuestSpec.botIDLabelKey] == runtime.storageID.value.uuidString.lowercased(),
                  mounts.contains(where: { ($0["Source"] as? String) == runtime.home.path && ($0["Destination"] as? String) == BotComputerGuestSpec.guestUserHome }) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            try docker.remove(name: try XCTUnwrap(object["Id"] as? String))
        }
        if try docker.networkExists(name: runtime.network) { try docker.removeNetwork(name: runtime.network) }
        guard try !docker.containerExists(name: runtime.name), try !docker.networkExists(name: runtime.network) else {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
    }

    func testMeasureOwnedDesktopColdCreationAndFivePairedWarmResumes() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1",
              ProcessInfo.processInfo.environment["RC_CONTEXT_RESOURCE_PROBE"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 RC_CONTEXT_RESOURCE_PROBE=1 for owned real-runtime cost measurement")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag) else {
            throw XCTSkip("cached guest image required; resource measurement never builds or pulls it")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
            .appendingPathComponent("RuntimeCost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var owned: [Runtime] = []
        defer {
            var clean = true
            for runtime in owned {
                do { try removeOwned(runtime, docker: docker) }
                catch { clean = false; XCTFail("owned runtime cleanup failed; fixture retained: \(root.lastPathComponent)") }
            }
            if clean { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        }
        let (legacyID, binding): (BotID, BotContextBinding) = try {
            let db = try SQLiteDB(path: root.appendingPathComponent("owned.sqlite").path)
            try Schema.migrate(db)
            let store = BotStore(db: db)
            let legacy = try store.create(name: "Cost legacy", title: "Cost legacy", description: "", soul: "", provider: .distill, model: "desktop-only")
            let contextual = try store.create(name: "Cost scoped", title: "Cost scoped", description: "", soul: "", provider: .distill, model: "desktop-only")
            let binding = try store.grantContext(hostID: "owned-resource-probe", botID: contextual.id, context: .general,
                actions: [.read, .send], expectedRevision: 0)
            return (legacy.id, binding)
        }()
        let scopedID = try BotContextRuntimeIdentity(binding: binding).storageBotID
        let setups: [(String, BotID, BotContextBinding?)] = [("legacy", legacyID, nil), ("contextual", scopedID, binding)]
        for (variant, id, binding) in setups {
            let support = root.appendingPathComponent(variant, isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let runtime = Runtime(variant: variant, support: support, storageID: id, binding: binding,
                service: BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil))
            guard try !docker.containerExists(name: runtime.name), try !docker.networkExists(name: runtime.network) else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            owned.append(runtime)
        }
        var measurements: [Sample] = []
        for runtime in owned { measurements.append(try sample(runtime, index: 0, cold: true, docker: docker)) }
        for index in 1...5 {
            let order = index.isMultiple(of: 2) ? Array(owned.reversed()) : owned
            for runtime in order { measurements.append(try sample(runtime, index: index, cold: false, docker: docker)) }
        }
        XCTAssertEqual(measurements.filter { $0.variant == "legacy" && $0.resumed }.count, 5)
        XCTAssertEqual(measurements.filter { $0.variant == "contextual" && $0.resumed }.count, 5)
        let rawInfo = try docker.run(["info", "--format", "{{json .}}"])
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: rawInfo) as? [String: Any])
        let encoded = try JSONEncoder().encode(measurements)
        let report: [String: Any] = [
            "schema_version": 1,
            "workload": "post-readiness desktop startup; no provider execution",
            "cold_definition": "first owned scope/container creation with cached image and running Docker engine",
            "warm_definition": "stopped same container resumed; other measured desktop stays idle",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "docker_cpus": try XCTUnwrap(info["NCPU"] as? Int),
            "docker_memory_bytes": try XCTUnwrap(info["MemTotal"] as? Int64),
            "docker_version": try XCTUnwrap(info["ServerVersion"] as? String),
            "image_id": try docker.imageID(tag: BotComputerGuestSpec.imageTag),
            "samples": try JSONSerialization.jsonObject(with: encoded)
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let reportURL = root.deletingLastPathComponent().appendingPathComponent("context-runtime-cost-\(UUID().uuidString).json")
        try json.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        print("CONTEXT_RUNTIME_COST_REPORT: " + reportURL.lastPathComponent)
    }
    private struct ConcurrencySample: Codable {
        let concurrent: Int
        let phase: String
        let index: Int
        let wallMilliseconds: Double
        let slowestMilliseconds: Double
        let failures: Int
        let totalMemoryMiB: Double
        let maxCPUPercent: Double
    }

    private func memoryMiB(_ text: String) throws -> Double {
        let used = try XCTUnwrap(text.split(separator: "/").first).trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("GiB", 1024), ("MiB", 1), ("KiB", 1.0 / 1024)]
        for (unit, factor) in units where used.hasSuffix(unit) {
            return try XCTUnwrap(Double(used.dropLast(unit.count))) * factor
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    func testMeasureSimultaneousContextualDesktopsAtOneTwoFourEight() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1",
              ProcessInfo.processInfo.environment["RC_CONTEXT_RESOURCE_PROBE"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 RC_CONTEXT_RESOURCE_PROBE=1 for owned real-runtime concurrency measurement")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag) else {
            throw XCTSkip("cached guest image required; resource measurement never builds or pulls it")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
            .appendingPathComponent("RuntimeConcurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var owned: [Runtime] = []
        defer {
            var clean = true
            for runtime in owned {
                do { try removeOwned(runtime, docker: docker) }
                catch { clean = false; XCTFail("owned runtime cleanup failed; fixture retained: \(root.lastPathComponent)") }
            }
            if clean { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        }
        let db = try SQLiteDB(path: root.appendingPathComponent("owned.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        var samples: [ConcurrencySample] = []
        for level in [1, 2, 4, 8] {
            var group: [Runtime] = []
            for n in 0..<level {
                let bot = try store.create(name: "Conc \(level)-\(n)", title: "Conc", description: "", soul: "", provider: .distill, model: "desktop-only")
                let binding = try store.grantContext(hostID: "owned-concurrency-probe", botID: bot.id, context: .general,
                    actions: [.read, .send], expectedRevision: 0)
                let storage = try BotContextRuntimeIdentity(binding: binding).storageBotID
                let support = root.appendingPathComponent("l\(level)-\(n)", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let runtime = Runtime(variant: "contextual", support: support, storageID: storage, binding: binding,
                    service: BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil))
                guard try !docker.containerExists(name: runtime.name), try !docker.networkExists(name: runtime.network) else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
                owned.append(runtime)
                group.append(runtime)
            }
            for index in 0...5 {
                if index > 0 {
                    for runtime in group { try runtime.service.stopForContextRecovery(identity: BotContextRuntimeIdentity(binding: try XCTUnwrap(runtime.binding))) }
                }
                let lock = NSLock()
                var durations = [Double](repeating: 0, count: level)
                var failures = 0
                let wallStart = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.concurrentPerform(iterations: level) { slot in
                    let runtime = group[slot]
                    let start = DispatchTime.now().uptimeNanoseconds
                    var failed = false
                    do { _ = try runtime.service.provision(contextBinding: try XCTUnwrap(runtime.binding), workspace: nil, registeredWorkspaces: []) }
                    catch { failed = true }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    lock.withLock { durations[slot] = elapsed; if failed { failures += 1 } }
                }
                let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
                var memory = 0.0
                var cpu = 0.0
                for runtime in group where failures == 0 {
                    let raw = try docker.run(["stats", "--no-stream", "--format", "{{json .}}", runtime.name])
                    let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
                    memory += try memoryMiB(try XCTUnwrap(stats["MemUsage"] as? String))
                    cpu = max(cpu, try XCTUnwrap(Double(try XCTUnwrap(stats["CPUPerc"] as? String).replacingOccurrences(of: "%", with: ""))))
                }
                samples.append(ConcurrencySample(concurrent: level, phase: index == 0 ? "cold_cached_image" : "warm_resume", index: index,
                    wallMilliseconds: wall, slowestMilliseconds: durations.max() ?? 0, failures: failures, totalMemoryMiB: memory, maxCPUPercent: cpu))
                XCTAssertEqual(failures, 0, "level \(level) sample \(index) must provision every desktop")
            }
            for runtime in group {
                try runtime.service.stopForContextRecovery(identity: BotContextRuntimeIdentity(binding: try XCTUnwrap(runtime.binding)))
            }
        }
        let encoded = try JSONEncoder().encode(samples)
        let rawInfo = try docker.run(["info", "--format", "{{json .}}"])
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: rawInfo) as? [String: Any])
        let report: [String: Any] = [
            "schema_version": 1,
            "workload": "post-readiness contextual desktop provisioning; no provider execution",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "docker_cpus": try XCTUnwrap(info["NCPU"] as? Int),
            "docker_memory_bytes": try XCTUnwrap(info["MemTotal"] as? Int64),
            "docker_version": try XCTUnwrap(info["ServerVersion"] as? String),
            "image_id": try docker.imageID(tag: BotComputerGuestSpec.imageTag),
            "samples": try JSONSerialization.jsonObject(with: encoded)
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let reportURL = root.deletingLastPathComponent().appendingPathComponent("context-runtime-concurrency-\(UUID().uuidString).json")
        try json.write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        print("CONTEXT_RUNTIME_CONCURRENCY_REPORT: " + reportURL.lastPathComponent)
    }
}
