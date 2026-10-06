import XCTest
import CryptoKit
import CoreModel
import Persistence
@testable import AppShell

private final class FakeDocker: BotComputerDockerClienting, @unchecked Sendable {
    var infoText = "ok"
    var infoFails = false
    var images: Set<String> = [BotComputerGuestSpec.imageTag]
    var containers: [String: BotComputerContainerInspect] = [:]
    var png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
    var created: [String] = []
    var createdOptions: [BotComputerContainerCreateOptions] = []
    var removed: [String] = []
    var removeError: Error?
    var started: [String] = []
    var stopped: [String] = []
    var builds: [URL] = []
    var execCalls = 0
    var execFailuresRemaining = 0
    var execError: Error?
    var lastExec: (name: String, command: [String], user: String?, detach: Bool)?
    var lastExecAt: Date?
    /// Stands in for a cold `docker start` + desktop boot during provisioning.
    var startDelay: TimeInterval = 0
    var networks: [String] = []
    var removedNetworks: [String] = []
    var networkError: Error?
    var renamed: [(String, String)] = []
    var imageLabels: [String: String] = [
        BotComputerGuestSpec.imageTag: BotComputerGuestSpec.recipeRevision
    ]
    /// `remotecode.recipe.sha256` per tag; the base image starts as built from the bundled recipe.
    var imageDigests: [String: String] = [
        BotComputerGuestSpec.imageTag: AppShellResourceBundle.computerGuestRecipeURL()
            .map { BotComputerGuestSpec.recipeDigest(context: $0) } ?? "",
    ]
    /// Ordered start/stop log, e.g. "stop:<name>".
    var lifecycle: [String] = []
    /// Runs while `docker build` is in progress.
    var onBuild: (() -> Void)?
    /// Answers an exec instead of `png` when it returns non-nil.
    var execOutput: (([String]) -> Data?)?

    func info() throws -> String {
        if infoFails { throw BotComputerGuestError.dockerUnavailable }
        return infoText
    }
    func imageExists(tag: String) throws -> Bool { images.contains(tag) }
    func imageLabel(tag: String, key: String) throws -> String {
        switch key {
        case BotComputerGuestSpec.recipeLabelKey: return imageLabels[tag] ?? ""
        case BotComputerGuestSpec.recipeDigestLabelKey: return imageDigests[tag] ?? ""
        default: return ""
        }
    }
    func imageID(tag: String) throws -> String {
        guard images.contains(tag) else { throw BotComputerGuestError.dockerUnavailable }
        return "img"
    }
    func build(context: URL, tag: String) throws {
        builds.append(context)
        onBuild?()
        images.insert(tag)
        imageLabels[tag] = BotComputerGuestSpec.recipeRevision
        imageDigests[tag] = BotComputerGuestSpec.recipeDigest(context: context)
    }
    func create(options: BotComputerContainerCreateOptions) throws -> String {
        created.append(options.name)
        createdOptions.append(options)
        containers[options.name] = BotComputerContainerInspect(
            running: false, imageID: "img", hostPort: 49152, labels: options.labels
        )
        return options.name
    }
    func start(name: String) throws {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        started.append(name)
        lifecycle.append("start:\(name)")
        containers[name] = BotComputerContainerInspect(
            running: true, imageID: "img", hostPort: 49152, labels: containers[name]?.labels ?? [:]
        )
    }
    func stop(name: String) throws {
        stopped.append(name)
        lifecycle.append("stop:\(name)")
        if var value = containers[name] {
            value.running = false
            containers[name] = value
        }
    }
    func inspect(name: String) throws -> BotComputerContainerInspect {
        guard let value = containers[name] else { throw BotComputerGuestError.notReady }
        return value
    }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
        execCalls += 1
        lastExec = (name, command, user, detach)
        lastExecAt = Date()
        if execFailuresRemaining > 0 {
            execFailuresRemaining -= 1
            throw BotComputerGuestError.observeFailed
        }
        if let execError { throw execError }
        if let output = execOutput?(command) { return output }
        return png
    }
    func rename(from: String, to: String) throws {
        renamed.append((from, to))
        containers[to] = containers[from]
        containers[from] = nil
    }
    func ensureNetwork(name: String) throws {
        networks.append(name)
        if let networkError { throw networkError }
    }
    func removeNetwork(name: String) throws {
        removedNetworks.append(name)
    }
    func remove(name: String) throws {
        removed.append(name)
        if let removeError { throw removeError }
        containers[name] = nil
    }
    func removeMatching(namePrefix: String) throws {
        for name in containers.keys where name.hasPrefix(namePrefix) {
            try remove(name: name)
        }
    }
}

@MainActor
final class BotComputerGuestServiceTests: XCTestCase {
    func test_guestInputStepsAcceptsIntegralJSONNumbersForPointerAndDrag() throws {
        // WHY: JSONValue stores every JSON number as a Double before the
        // paired router reaches this parser; integral coordinates must keep
        // their exact values instead of being rejected as non-Int payloads.
        let pointer = try AppCommandRouter.guestInputSteps([
            "input": [
                "kind": "pointer",
                "x": 320.0,
                "y": 480.0,
            ],
        ])
        XCTAssertEqual(pointer, [BotComputerActStep(action: "click", x: 320, y: 480)])

        let drag = try AppCommandRouter.guestInputSteps([
            "input": [
                "kind": "drag",
                "from_x": 40.0,
                "from_y": 80.0,
                "to_x": 640.0,
                "to_y": 960.0,
            ],
        ])
        XCTAssertEqual(
            drag,
            [BotComputerActStep(action: "drag", x: 40, y: 80, toX: 640, toY: 960)]
        )
    }

    func test_guestInputStepsRejectsFractionalOrMalformedCoordinates() {
        let invalidInputs: [[String: Any]] = [
            ["kind": "pointer", "x": 10.5, "y": 20.0],
            ["kind": "pointer", "x": 10.0],
            [
                "kind": "drag",
                "from_x": 10.0,
                "from_y": 20.0,
                "to_x": 30.5,
                "to_y": 40.0,
            ],
        ]

        for input in invalidInputs {
            XCTAssertThrowsError(
                try AppCommandRouter.guestInputSteps(["input": input]),
                "invalid coordinate payload must remain rejected: \(input)"
            )
        }
    }

    func test_guestFrameReadbackAdvancesExactFrameAndFailureInvalidatesGrant() throws {
        // WHY: Docker's physical inspect identity validates the capture, but it
        // must not replace the logical image identity authorized by the recipe.
        let runtime: [String: Any] = [
            "host_id": "host",
            "bot_id": UUID().uuidString.lowercased(),
            "container_id": "container",
            "app_run_id": "app-run",
            "viewer_id": "viewer",
            "viewer_path": "/vnc.html",
            "session_id": "session",
            "grant_id": "grant",
            "grant_generation": 7,
            "recipe_id": "recipe",
            "image_reference": "recipe-image",
        ]
        let context: [String: Any] = [
            "runtime": runtime,
            "frame": [
                "frame_id": "before-frame",
                "sequence": 11,
            ],
        ]
        let png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xb0,
        ])
        let evidence = BotComputerGuestFrameEvidence(
            containerID: "container",
            imageReference: "sha256:runtime-image",
            viewerPath: "/vnc.html",
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            png: png,
            pngHash: "png-hash"
        )

        let readback = AppCommandRouter.guestFrameReadback(context: context, evidence: evidence)

        let frame = try XCTUnwrap(readback["frame"] as? [String: Any])
        let afterFrameID = try XCTUnwrap(frame["frame_id"] as? String)
        XCTAssertNotEqual(afterFrameID, "before-frame")
        XCTAssertEqual(frame["sequence"] as? Int, 12)
        XCTAssertEqual(frame["png_base64"] as? String, png.base64EncodedString())
        XCTAssertEqual(frame["png_hash"] as? String, "png-hash")
        XCTAssertEqual(readback["before_frame_id"] as? String, "before-frame")
        XCTAssertEqual(readback["after_frame_id"] as? String, afterFrameID)
        XCTAssertNotEqual(evidence.imageReference, runtime["image_reference"] as? String)
        XCTAssertEqual((readback["runtime"] as? [String: Any])?["image_reference"] as? String, "recipe-image")
        XCTAssertEqual((frame["runtime"] as? [String: Any])?["image_reference"] as? String, "recipe-image")

        let failed = AppCommandRouter.guestFailureReadback(context: readback, message: "capture failed")
        XCTAssertNil(failed["runtime"])
        XCTAssertNil(failed["frame"])
        XCTAssertEqual(failed["grant_generation"] as? Int, 8)
        XCTAssertEqual(failed["grant_invalidated"] as? Bool, true)
        XCTAssertEqual(
            (failed["recovery"] as? [String: Any])?["requires_new_start_grant"] as? Bool,
            true
        )
    }

    func test_remoteFrameExportsBoundedPNGIdentityWithoutViewerSecret() throws {
        let support = makeSupport("rc-guest-remote-frame")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xb0,
        ])
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()

        let ready = try service.provision(botID: botID)
        let frame = try service.remoteFrame(botID: botID, ready: ready)

        XCTAssertEqual(frame.containerID, BotComputerGuestSpec.containerName(botID: botID))
        XCTAssertEqual(frame.imageReference, "img")
        XCTAssertEqual(frame.viewerPath, "/vnc.html")
        XCTAssertEqual(frame.pixelWidth, 1_600)
        XCTAssertEqual(frame.pixelHeight, 1_200)
        XCTAssertEqual(frame.png, fake.png)
        XCTAssertEqual(frame.pngHash.count, 64)
        XCTAssertEqual(fake.execCalls, 1, "the frame proven during readiness must be exported without recapture")
    }

    func test_remoteFrameFailsClosedWithoutProvisioningAnAbsentGuest() throws {
        // WHY: a remote frame belongs to the exact accepted Guest runtime;
        // silently provisioning here could replace its container or session.
        let support = makeSupport("rc-guest-remote-frame-absent")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        XCTAssertThrowsError(try service.remoteFrame(botID: BotID()))
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertEqual(fake.execCalls, 0)
    }

    func test_remoteFrameRejectsReadinessEvidenceFromAnotherBotWithoutRecapture() throws {
        // WHY: readiness evidence is authoritative only for its exact Bot and
        // canonical container, even when another Guest is concurrently ready.
        let support = makeSupport("rc-guest-remote-frame-cross-bot")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let firstBot = BotID()
        let secondBot = BotID()
        let firstReady = try service.provision(botID: firstBot)
        _ = try service.provision(botID: secondBot)

        XCTAssertThrowsError(try service.remoteFrame(botID: secondBot, ready: firstReady))
        XCTAssertEqual(fake.execCalls, 2, "rejecting cross-Bot evidence must not capture or replay")
    }

    func test_concurrentProveReadyDoesNotRaceOnLastReady_becauseStudioOpensCanOverlapProbes() throws {
        // WHY: Studio opens can overlap probes while other code reads their published status.
        let support = makeSupport("rc-guest-concurrent-probes")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.infoFails = true
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let readerDone = DispatchSemaphore(value: 0)
        let stop = NSLock()
        var stopped = false
        DispatchQueue.global().async {
            while !stop.withLock({ stopped }) {
                _ = service.lastReady
                _ = service.lastReason
            }
            readerDone.signal()
        }
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            _ = service.proveReady()
        }
        stop.withLock { stopped = true }
        XCTAssertEqual(readerDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(service.lastReady)
        XCTAssertEqual(service.lastReason, String(describing: BotComputerGuestError.dockerUnavailable))
    }

    func test_proveReadyRequiresPNGAndLoopback() throws {
        // WHY: Studio must not enable Docker desktop on a JPEG or a LAN bind.
        let support = makeSupport("rc-guest-svc")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 2,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
        XCTAssertEqual(service.lastReady?.pngMagic, BotComputerGuestService.pngMagicHex)
        XCTAssertTrue(fake.networks.isEmpty)
        XCTAssertNil(fake.createdOptions.first?.network)
        let viewerToken = try XCTUnwrap(
            fake.createdOptions.first?.environment["REMOTECODE_VIEWER_TOKEN"]
        )
        XCTAssertEqual(viewerToken.count, 36)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(service.lastReady?.screenURL), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
            "websockify?token=\(viewerToken)"
        )
        fake.png = Data("jpeg".utf8)
        XCTAssertFalse(service.proveReady())
        XCTAssertTrue(fake.created.allSatisfy { name in fake.removed.contains(name) })
    }

    func test_provisionAndRebuildAlwaysUseTheBotsDedicatedNetwork() throws {
        // WHY: separate network names remain useful defense in depth, while
        // the viewer token is the reliable boundary on runtimes that route
        // traffic across bridges.
        let support = makeSupport("rc-guest-network-isolation")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()

        let ready = try service.provision(botID: botID)

        let rebuilt = try service.rebuild(botID: botID)

        XCTAssertEqual(
            fake.networks,
            Array(repeating: BotComputerGuestSpec.networkName(botID: botID), count: 2)
        )
        let network = BotComputerGuestSpec.networkName(botID: botID)
        XCTAssertTrue(fake.createdOptions.allSatisfy { $0.network == network })
        let viewerTokens = Set(
            fake.createdOptions.compactMap { $0.environment["REMOTECODE_VIEWER_TOKEN"] }
        )
        XCTAssertEqual(viewerTokens.count, 1, "rebuild must preserve the Bot's viewer credential")
        XCTAssertEqual(ready.screenURL.host, "127.0.0.1")
        XCTAssertEqual(rebuilt.screenURL.host, "127.0.0.1")
        service.teardown(botID: botID)
        XCTAssertEqual(fake.removedNetworks, [network])
    }

    func test_eachBotPersistsADistinctViewerToken() throws {
        // WHY: routable container networks must not let one Bot reuse its own
        // viewer credential to open a different Bot's desktop.
        let support = makeSupport("rc-guest-viewer-token")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let first = BotID()
        let second = BotID()

        _ = try service.provision(botID: first)
        let firstToken = try XCTUnwrap(
            fake.createdOptions.last?.environment["REMOTECODE_VIEWER_TOKEN"]
        )
        service.teardown(botID: first)
        _ = try service.provision(botID: second)
        let secondToken = try XCTUnwrap(
            fake.createdOptions.last?.environment["REMOTECODE_VIEWER_TOKEN"]
        )

        XCTAssertNotEqual(firstToken, secondToken)
    }

    func test_resumedContainerKeepsViewerTokenAfterGuestHomeIsCleared() throws {
        // WHY: the Bot can delete anything inside its mounted home. That must
        // not rotate the host-owned bearer away from the still-running
        // websockify process and strand the resumed viewer.
        let support = makeSupport("rc-guest-viewer-token-resume")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        _ = try service.provision(botID: botID)
        let originalToken = try XCTUnwrap(
            fake.createdOptions.last?.environment["REMOTECODE_VIEWER_TOKEN"]
        )
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID)
        try service.stop(botID: botID)
        try FileManager.default.removeItem(at: home)

        let resumed = try service.provision(botID: botID)

        let path = URLComponents(url: resumed.screenURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value
        XCTAssertTrue(resumed.resumed)
        XCTAssertEqual(fake.createdOptions.count, 1, "resume must keep the existing container")
        XCTAssertEqual(path, "websockify?token=\(originalToken)")
        service.teardown(botID: botID)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: BotComputerGuestSpec.viewerTokenURL(appSupport: support, botID: botID).path
            )
        )
    }

    func test_addressPoolFailureNeverFallsBackToTheSharedBridge() throws {
        // WHY: availability cannot weaken cross-Bot isolation. The real CLI
        // recovers with an explicit /30; if it cannot, provisioning must fail.
        let support = makeSupport("rc-guest-network-exhausted")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.networkError = BotComputerDockerError.networkAddressPoolExhausted
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        XCTAssertThrowsError(try service.provision(botID: BotID())) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .networkAddressPoolExhausted)
        }
        XCTAssertTrue(fake.createdOptions.isEmpty)
    }

    func test_provisionDoesNotHideNonPoolNetworkFailures() throws {
        // WHY: daemon and permission failures must remain visible instead of
        // creating a container with weaker-than-requested isolation.
        let support = makeSupport("rc-guest-network-failure")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.networkError = BotComputerDockerError.provisioningFailed
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        XCTAssertThrowsError(try service.provision(botID: BotID())) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
        }
        XCTAssertTrue(fake.created.isEmpty)
    }

    func test_oversizedDockerOutputFailsWithoutRepeatingTheCapture() throws {
        // WHY: a bounded exact-output reader already proved this frame cannot
        // fit; retrying it repeatedly only recreates the memory pressure.
        let support = makeSupport("rc-guest-output-limit")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execError = BotComputerDockerError.outputTooLarge
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 3,
            observeDelay: 0
        )

        XCTAssertThrowsError(try service.provision(botID: BotID())) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .outputTooLarge)
        }
        XCTAssertEqual(fake.execCalls, 1)
    }

    func test_proveReadyBuildsBundledRecipeWhenImageMissing() throws {
        // WHY: Studio must build the base image from the bundled
        // ComputerGuest recipe instead of staying disabled forever.
        let support = makeSupport("rc-guest-build")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let fake = FakeDocker()
        fake.images = []
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: recipe,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe])
        XCTAssertTrue(fake.images.contains(BotComputerGuestSpec.imageTag))
        XCTAssertEqual(service.lastReady?.pngMagic, "89504e47")
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
    }

    func test_proveReadyFailsClosedWithoutRecipeWhenImageMissing() throws {
        let support = makeSupport("rc-guest-norecipe")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.images = []
        let service = BotComputerGuestService(appSupport: support, docker: fake)
        XCTAssertFalse(service.proveReady())
        XCTAssertEqual(service.lastReason, "Docker image missing")
        XCTAssertTrue(fake.builds.isEmpty)
        XCTAssertTrue(fake.created.isEmpty)
    }

    func test_proveReadyRebuildsImageWhenRecipeRevisionIsStale() throws {
        // WHY: viewer admission changes do nothing if Studio keeps an older,
        // unauthenticated base image.
        let support = makeSupport("rc-guest-stale")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let fake = FakeDocker()
        fake.imageLabels = [:]
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: recipe,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe])
        XCTAssertEqual(fake.imageLabels[BotComputerGuestSpec.imageTag], BotComputerGuestSpec.recipeRevision)
    }

    func test_staleCustomImageCannotBypassCurrentViewerAdmission() throws {
        // WHY: a Bot image built before TokenFile admission must not be resumed
        // merely because its tag still exists; its editable recipe remains on
        // disk for an explicit rebuild.
        let support = makeSupport("rc-guest-stale-custom")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let botID = BotID()
        let customTag = BotComputerGuestSpec.botImageTag(botID: botID)
        fake.images.insert(customTag)
        fake.imageLabels[customTag] = "2"
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        _ = try service.provision(botID: botID)

        XCTAssertEqual(fake.createdOptions.last?.image, BotComputerGuestSpec.imageTag)
    }

    func test_provisionRecreatesContainerWhenImageIsStale() throws {
        let support = makeSupport("rc-guest-recreate")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        fake.containers[name] = BotComputerContainerInspect(
            running: true, imageID: "old-viewonly", hostPort: 49152
        )
        let ready = try service.provision(botID: botID)
        XCTAssertFalse(ready.resumed)
        XCTAssertTrue(fake.removed.contains(name))
        XCTAssertTrue(fake.created.contains(name))
        service.teardown(botID: botID)
    }

    func test_proveReadyRetriesUntilPNGThenRemovesProbe() throws {
        // WHY: Xvfb is not a PNG on the first exec. A single import would
        // flake the Studio radio and leak remotecode-probe-*.
        let support = makeSupport("rc-guest-retry")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 2
        let slept = SleepCounter()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 4,
            observeDelay: 0.01,
            sleep: { _ in slept.count += 1 }
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.execCalls, 3)
        XCTAssertEqual(slept.count, 2)
        XCTAssertEqual(fake.created.count, 1)
        XCTAssertEqual(fake.removed, fake.created)
        XCTAssertTrue(fake.containers.isEmpty)
        XCTAssertEqual(service.lastReady?.pngMagic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
    }

    func test_proveReadyScavengesLeftoverProbes() throws {
        let support = makeSupport("rc-guest-scavenge")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.containers["remotecode-probe-stale"] = BotComputerContainerInspect(
            running: false, imageID: "img", hostPort: 1
        )
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertFalse(fake.containers.keys.contains("remotecode-probe-stale"))
        XCTAssertTrue(fake.removed.contains("remotecode-probe-stale"))
    }

    func test_proveReadyRemovesProbeWhenPNGNeverArrives() throws {
        let support = makeSupport("rc-guest-leak")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 99
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 3,
            observeDelay: 0
        )
        XCTAssertFalse(service.proveReady())
        XCTAssertEqual(fake.execCalls, 3)
        XCTAssertEqual(fake.removed, fake.created)
        XCTAssertTrue(fake.containers.isEmpty)
        XCTAssertNil(service.lastReady)
    }

    func test_observeAndActDriveTheGuestThroughDockerExec() throws {
        // WHY: dockerDesktop tools must screenshot and click the guest,
        // not this Mac. Fake docker records the exact exec argv.
        let support = makeSupport("rc-guest-act")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let shot = try service.observe(botID: botID)
        XCTAssertEqual(shot.magic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(shot.png.prefix(4), BotComputerGuestObserve.pngSignature)
        try service.act(botID: botID, steps: [
            BotComputerActStep(action: "click", x: 40, y: 80),
            BotComputerActStep(action: "type", text: "hello"),
        ])
        XCTAssertTrue(fake.execCalls >= 3)
        service.teardown(botID: botID)
    }

    func test_applyObserveReturnsTheFullBoundedPNGResult() throws {
        // WHY: a valid guest screenshot must keep the public MCP result shape
        // and bytes; the bound must prevent an unbounded base64 result without
        // silently truncating a valid image.
        let support = makeSupport("rc-guest-result-bound")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let result = try service.apply(BotComputerPendingAction(
            id: "observe-result",
            botID: botID.value.uuidString,
            kind: BotComputerCatalog.observe
        ))
        let base64 = try XCTUnwrap(result["png_base64"] as? String)

        XCTAssertEqual(Set(result.keys), Set(["png_magic", "png_hash", "png_base64", "host", "image"]))
        XCTAssertEqual(Data(base64Encoded: base64), fake.png)
        XCTAssertLessThanOrEqual(base64.utf8.count, BotComputerGuestService.maxScreenshotBase64Bytes)
        service.teardown(botID: botID)
    }

    func test_applyObserveFailsClosedForAnOversizedPNG() throws {
        // WHY: oversized PNG output must produce an explicit failure rather
        // than silently truncating a valid tool result into a corrupt image.
        let support = makeSupport("rc-guest-result-overflow")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.png = BotComputerGuestObserve.pngSignature + Data(
            repeating: 0,
            count: BotComputerGuestService.maxScreenshotBytes - BotComputerGuestObserve.pngSignature.count + 1
        )
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()

        XCTAssertThrowsError(try service.apply(BotComputerPendingAction(
            id: "observe-overflow",
            botID: botID.value.uuidString,
            kind: BotComputerCatalog.observe
        ))) { error in
            XCTAssertEqual(
                error as? BotComputerGuestServiceError,
                .screenshotTooLarge(
                    actualBytes: BotComputerGuestService.maxScreenshotBytes + 1,
                    maximumBytes: BotComputerGuestService.maxScreenshotBytes
                )
            )
        }
    }

    func test_reconcileBotComputerActionsRunsWorkerOffMainActor() throws {
        // WHY: distributed notifications are delivered on the main queue, but
        // Docker provisioning and PNG polling must never block MainActor.
        let support = makeSupport("rc-guest-reconcile-off-main")
        defer { try? FileManager.default.removeItem(at: support) }
        let context = try AppContext(channel: .debug, appSupportOverride: support.path)
        let router = AppCommandRouter(context: context)
        let probe = ReconciliationWorkerProbe()
        router.botComputerReconciliationWorkerForTesting = {
            probe.record(ranOnMainThread: Thread.isMainThread)
        }

        router.reconcileBotComputerActions()

        XCTAssertTrue(probe.wait(timeout: 1), "reconciliation worker did not run")
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func test_provisionRetriesUntilPNG() throws {
        let support = makeSupport("rc-guest-prov-retry")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.execFailuresRemaining = 1
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 3,
            observeDelay: 0
        )
        let botID = BotID()
        let first = try service.provision(botID: botID)
        XCTAssertFalse(first.resumed)
        XCTAssertEqual(first.pngMagic, BotComputerGuestService.pngMagicHex)
        XCTAssertEqual(fake.execCalls, 2)
        let second = try service.provision(botID: botID)
        XCTAssertTrue(second.resumed)
        service.teardown(botID: botID)
        XCTAssertThrowsError(try fake.inspect(name: BotComputerGuestSpec.containerName(botID: botID)))
    }

    func test_removeGuestRuntimeVerifiesAbsenceAfterAnIdempotentRemoveError() throws {
        // WHY: deleting an already-absent runtime may make `docker rm` fail;
        // that must not leave a false container_runtime residual or block the
        // independent Bot Home cleanup axis.
        let support = makeSupport("rc-guest-remove-absent")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.removeError = BotComputerGuestError.notReady
        let service = BotComputerGuestService(appSupport: support, docker: fake)

        XCTAssertNoThrow(try service.removeGuestRuntime(botID: BotID()))
    }

    func test_removeGuestRuntimeKeepsFailureWhenCanonicalContainerStillExists() throws {
        // WHY: an idempotent verifier may clear a false-positive error only
        // after it proves the exact container is absent.
        let support = makeSupport("rc-guest-remove-present")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let botID = BotID()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        fake.containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49_152)
        fake.removeError = BotComputerGuestError.notReady
        let service = BotComputerGuestService(appSupport: support, docker: fake)

        XCTAssertThrowsError(try service.removeGuestRuntime(botID: botID))
        XCTAssertNotNil(fake.containers[name])
    }

    func test_absentRuntimeVerificationProducesACompletedDeleteReceiptAndWipesHome() throws {
        // WHY: an idempotent Docker error with no remaining runtime must not
        // turn an otherwise complete authoritative deletion into partial.
        let support = makeSupport("rc-guest-delete-absent")
        defer { try? FileManager.default.removeItem(at: support) }
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: SettingsStore(db: db),
            appSupportDirectory: support
        )
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "absent-create", "name": "Absent runtime",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let botUUID = try XCTUnwrap(UUID(uuidString: botID))
        _ = try authority.dispatch(method: "bot.guest.state", params: [
            "host_id": "host", "bot_id": botID,
        ])
        _ = try BotGuestHome.ensure(appSupport: support, botID: BotID(botUUID))
        let fake = FakeDocker()
        fake.removeError = BotComputerGuestError.notReady
        let service = BotComputerGuestService(appSupport: support, docker: fake)
        var teardownCount = 0
        authority.onDockerClear = { id in
            teardownCount += 1
            try service.removeGuestRuntime(botID: id)
        }
        let params: [String: Any] = [
            "client_request_id": "absent-delete", "bot_id": botID, "confirm": "delete",
        ]

        let deleted = try authority.dispatch(method: "bot.delete", params: params)
        let replay = try authority.dispatch(method: "bot.delete", params: params)

        XCTAssertEqual(deleted["status"] as? String, "completed")
        XCTAssertEqual(replay["receipt_id"] as? String, deleted["receipt_id"] as? String)
        XCTAssertEqual(teardownCount, 1, "terminal receipt replay must not redispatch cleanup")
        let readback = try XCTUnwrap(deleted["readback"] as? [String: Any])
        XCTAssertEqual(readback["cleanup_complete"] as? Bool, true)
        XCTAssertEqual(readback["cleanup_residuals"] as? [String], [])
        XCTAssertNotNil(try store.get(id: BotID(botUUID))?.deletedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotGuestHome.url(appSupport: support, botID: BotID(botUUID)).path))
    }

    func test_liveProveReady_emitsPNGMagicAndLoopback() throws {
        // WHY: skeptic rejected a custom docker wait script. Studio's
        // shipped proveReady() must itself return PNG 89 50 4E 47 on
        // remotecode/computer:r5 bound to 127.0.0.1.
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 to run the shipped proveReady capture")
        }
        let docker = BotComputerDockerCLI()
        do {
            _ = try docker.info()
        } catch {
            throw XCTSkip("docker info unavailable: \(error)")
        }
        let support = makeSupport("rc-guest-live")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(
            AppShellResourceBundle.computerGuestRecipeURL(),
            "bundled ComputerGuest recipe must exist so proveReady can build"
        )
        let service = BotComputerGuestService(
            appSupport: support,
            docker: docker,
            recipeContext: recipe,
            observeAttempts: 60,
            observeDelay: 0.5
        )
        let ready = service.proveReady()
        let magic = service.lastReady?.pngMagic ?? ""
        let host = service.lastReady?.screenURL.host ?? ""
        let image = BotComputerGuestSpec.imageTag
        print("PROVE_READY=\(ready ? 1 : 0)")
        print("PNG_MAGIC=\(magic)")
        print("HOST=\(host)")
        print("IMAGE=\(image)")
        print("REASON=\(service.lastReason)")
        XCTAssertTrue(ready, service.lastReason)
        XCTAssertEqual(magic, "89504e47")
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(image, "remotecode/computer:r5")

        let botID = BotID()
        let shot = try service.observe(botID: botID)
        print("OBSERVE_PNG_MAGIC=\(shot.magic)")
        print("OBSERVE_HOST=127.0.0.1")
        XCTAssertEqual(shot.magic, "89504e47")
        try service.act(botID: botID, steps: [BotComputerActStep(action: "key", key: "Return")])
        print("ACT_OK=1")
        service.teardown(botID: botID)
    }

    func test_provisionReplacesAContainerFromOlderCreateOptionsOnlyWhileIdle() throws {
        // WHY: a container created before runtime revision 2 has no agent-kit
        // bind, no --init and no host alias, so the in-guest agent cannot run
        // there. It must be replaced, but never under an active run, whose
        // processes live in that container.
        let support = makeSupport("rc-guest-runtime-label")
        defer { try? FileManager.default.removeItem(at: support) }
        let old = BotComputerContainerInspect(
            running: true, imageID: "img", hostPort: 49152,
            labels: [BotComputerGuestSpec.workspacesLabelKey: BotComputerGuestSpec.workspacesLabel([])]
        )

        let idleFake = FakeDocker()
        let idle = BotComputerGuestService(
            appSupport: support, docker: idleFake, observeAttempts: 1, observeDelay: 0,
            vmRuns: BotVMRunRegistry()
        )
        let idleBot = BotID()
        let idleName = BotComputerGuestSpec.containerName(botID: idleBot)
        idleFake.containers[idleName] = old
        XCTAssertFalse(try idle.provision(botID: idleBot).resumed)
        XCTAssertEqual(idleFake.removed, [idleName])
        XCTAssertEqual(idleFake.created, [idleName])
        let created = try XCTUnwrap(idleFake.createdOptions.last)
        XCTAssertTrue(created.initProcess)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BotComputerGuestSpec.guestToolsURL(appSupport: support).path
        ), "the kit's host directory exists before Docker binds it")
        idleFake.created.removeAll()
        let runAgent = BotComputerGuestSpec.guestToolsURL(appSupport: support)
            .appendingPathComponent("bin/run-agent")
        try FileManager.default.removeItem(at: runAgent)
        XCTAssertTrue(try idle.provision(botID: idleBot).resumed, "a current container is reused")
        XCTAssertTrue(idleFake.created.isEmpty)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: runAgent.path),
            "a reused container sees the agent kit through its bind, so provision restores it"
        )

        let busyFake = FakeDocker()
        let registry = BotVMRunRegistry()
        let busy = BotComputerGuestService(
            appSupport: support, docker: busyFake, observeAttempts: 1, observeDelay: 0,
            vmRuns: registry
        )
        let busyBot = BotID()
        busyFake.containers[BotComputerGuestSpec.containerName(botID: busyBot)] = old
        registry.begin(botID: busyBot, entry: .init(
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Fix CI", workspace: ""
        ))
        XCTAssertTrue(try busy.provision(botID: busyBot).resumed)
        XCTAssertTrue(busyFake.removed.isEmpty)
        XCTAssertTrue(busyFake.created.isEmpty)
    }

    func test_rebuildIsRefusedWhileAnotherThreadsRunHoldsTheBot() throws {
        // WHY: rebuild swaps out the container a running thread is using. The
        // user's Rebuild button (no thread) and other threads must wait; the
        // holding thread's own agent asking for it keeps working as before.
        let support = makeSupport("rc-guest-rebuild-busy")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let registry = BotVMRunRegistry()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: registry
        )
        let botID = BotID()
        let holder = AgentThreadID()
        registry.begin(botID: botID, entry: .init(
            threadID: holder, runID: AgentRunID(), title: "Fix CI", workspace: ""
        ))

        XCTAssertThrowsError(try service.rebuild(botID: botID)) {
            XCTAssertEqual($0 as? BotComputerGuestServiceError, .rebuildWhileRunActive(threadTitle: "Fix CI"))
        }
        XCTAssertThrowsError(try service.rebuild(botID: botID, requestingThreadID: AgentThreadID()))
        XCTAssertTrue(fake.builds.isEmpty, "nothing was built or replaced")
        XCTAssertTrue(fake.created.isEmpty)

        _ = try service.rebuild(botID: botID, requestingThreadID: holder)
        XCTAssertEqual(fake.builds.count, 1)
        registry.end(botID: botID, runID: try XCTUnwrap(registry.active(botID: botID)).runID)
        _ = try service.rebuild(botID: botID)
        XCTAssertEqual(fake.builds.count, 2, "an idle bot rebuilds from the button")
    }

    func test_prepareHomeReplacesTheUneditedRevision4RecipeAndKeepsEditedOnes() throws {
        // WHY: a bot's rebuild builds its per-bot copy of the recipe. A copy
        // still byte-equal to what revision 4 seeded was never edited and would
        // rebuild an image without the agent toolchain; an edited copy is the
        // user's and must stay.
        let r4 = """
        FROM debian:bookworm-slim

        ENV DEBIAN_FRONTEND=noninteractive \\
            HOME=/home/remotecode \\
            DISPLAY=:1

        RUN apt-get update && apt-get install -y --no-install-recommends \\
                xvfb \\
                fluxbox \\
                x11vnc \\
                novnc \\
                websockify \\
                chromium \\
                imagemagick \\
                xdotool \\
                x11-utils \\
                xterm \\
                ca-certificates \\
                nodejs \\
                npm \\
                python3 \\
            && rm -rf /var/lib/apt/lists/*

        RUN useradd --create-home --home-dir /home/remotecode --shell /bin/bash remotecode \\
            && mkdir -p /opt/remotecode-computer

        COPY start.sh /opt/remotecode-computer/start.sh
        COPY embed.html /opt/remotecode-computer/embed.html
        COPY launch-browser.sh /opt/remotecode-computer/launch-browser.sh
        RUN chmod 0755 /opt/remotecode-computer/start.sh /opt/remotecode-computer/launch-browser.sh

        USER remotecode
        WORKDIR /home/remotecode
        EXPOSE 6080
        CMD ["/opt/remotecode-computer/start.sh"]
        """ + "\n"
        XCTAssertEqual(
            SHA256.hash(data: Data(r4.utf8)).map { String(format: "%02x", $0) }.joined(),
            "f76708fdeadee4b8c2b970e6bcb0d1cf0143ed57331d14a14941406fbc438bb6",
            "the fixture must stay byte-identical to the revision 4 Dockerfile"
        )
        let support = makeSupport("rc-guest-recipe-r4")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let service = BotComputerGuestService(
            appSupport: support, docker: FakeDocker(), recipeContext: recipe,
            observeAttempts: 1, observeDelay: 0
        )
        let current = try String(contentsOf: recipe.appendingPathComponent("Dockerfile"), encoding: .utf8)

        let stockBot = BotID()
        let stockHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: stockBot)
        try FileManager.default.createDirectory(at: stockHome, withIntermediateDirectories: true)
        try r4.write(to: stockHome.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try service.prepareHome(botID: stockBot)
        XCTAssertEqual(try String(contentsOf: stockHome.appendingPathComponent("Dockerfile"), encoding: .utf8), current)

        let editedBot = BotID()
        let editedHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: editedBot)
        try FileManager.default.createDirectory(at: editedHome, withIntermediateDirectories: true)
        let edited = r4 + "RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg\n"
        try edited.write(to: editedHome.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        try service.prepareHome(botID: editedBot)
        XCTAssertEqual(try String(contentsOf: editedHome.appendingPathComponent("Dockerfile"), encoding: .utf8), edited)
    }

    func test_recipePreparationReassertsTheDockerIgnoreAfterAGuestEdit() throws {
        // WHY: the build context is the guest-writable home holding the agent's
        // credentials. A guest that rewrites .dockerignore to re-include
        // .distill must not get it into the next rebuilt image.
        let support = makeSupport("rc-guest-dockerignore")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake,
            recipeContext: try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL()),
            observeAttempts: 1, observeDelay: 0
        )
        let botID = BotID()
        try service.prepareHome(botID: botID)
        let ignore = BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID)
            .appendingPathComponent(".dockerignore")
        XCTAssertEqual(try String(contentsOf: ignore, encoding: .utf8), BotComputerGuestSpec.enforcedDockerIgnore(nil))

        try "!.distill\n!.distill/claude-auth.json\n".write(to: ignore, atomically: true, encoding: .utf8)
        _ = try service.rebuild(botID: botID)
        let lines = try String(contentsOf: ignore, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.suffix(3)), BotComputerGuestSpec.requiredDockerIgnorePatterns)
        XCTAssertEqual(fake.builds.last, BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID))

        // BuildKit reads Dockerfile.dockerignore instead of .dockerignore when
        // it exists (verified: an empty one put .distill/claude-auth.json into
        // the image); Podman reads .containerignore. Both get the exclusions.
        let recipe = BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID)
        for name in BotComputerGuestSpec.alternateDockerIgnoreFileNames {
            try "".write(to: recipe.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try service.rebuild(botID: botID)
        for name in BotComputerGuestSpec.alternateDockerIgnoreFileNames {
            let planted = try String(contentsOf: recipe.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(planted, BotComputerGuestSpec.enforcedDockerIgnore(""), name)
        }

        // A guest-planted symlink names a host path. The host must replace the
        // link, never read the file behind it into the guest-readable home.
        let hostSecret = support.appendingPathComponent("host-secret")
        try "HOST-PRIVATE-KEY\n".write(to: hostSecret, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: ignore)
        try FileManager.default.createSymbolicLink(at: ignore, withDestinationURL: hostSecret)
        _ = try service.rebuild(botID: botID)
        let replaced = try FileManager.default.attributesOfItem(atPath: ignore.path)[.type] as? FileAttributeType
        XCTAssertEqual(replaced, .typeRegular)
        XCTAssertFalse(try String(contentsOf: ignore, encoding: .utf8).contains("HOST-PRIVATE-KEY"))
        XCTAssertEqual(try String(contentsOf: hostSecret, encoding: .utf8), "HOST-PRIVATE-KEY\n")
    }

    func test_guestRunVMProbesTheAgentToolsOncePerImageAndNamesWhatIsMissing() throws {
        // WHY (plan A S8): an in-guest run needs the agent's tools in the
        // image (a stale or customised image may lack them); it must fail
        // naming them, not start a broken agent. The probe costs a docker
        // exec per turn, so a container keeps its result until it is recreated.
        let support = makeSupport("rc-guest-run-vm")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.infoText = "Server Version: 29.4.0\n Architecture: aarch64\n"
        var probes = 0
        var probeAnswer = "git wmctrl "
        fake.execOutput = { command in
            guard command.first == "sh", command.last == BotGuestDockerVM.toolsProbeScript else { return nil }
            probes += 1
            return Data(probeAnswer.utf8)
        }
        let service = BotComputerGuestService(
            appSupport: support, docker: fake,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1, observeDelay: 0
        )
        let vm = BotGuestDockerVM(appSupport: support, docker: fake, service: service)
        let botID = BotID()
        XCTAssertThrowsError(try vm.prepare(
            botID: botID, threadID: AgentThreadID(), workspace: nil, registeredWorkspaces: []
        )) { error in
            XCTAssertEqual(String(describing: error),
                           "VM indisponível: the bot's Linux image lacks git, wmctrl. "
                           + "Add them to the bot's Dockerfile, or restore the default one, and rebuild.")
        }
        XCTAssertEqual(fake.lastExec?.user, BotComputerGuestSpec.agentUser, "probed as the user the agent runs as")

        probeAnswer = ""
        let ready = try vm.prepare(botID: botID, threadID: AgentThreadID(), workspace: nil, registeredWorkspaces: [])
        XCTAssertEqual(ready, BotGuestVM(
            container: BotComputerGuestSpec.containerName(botID: botID), dockerArch: "aarch64", mountedWorkspaces: []
        ))
        _ = try vm.prepare(botID: botID, threadID: AgentThreadID(), workspace: nil, registeredWorkspaces: [])
        XCTAssertEqual(probes, 2, "a passed probe is reused while the container keeps its image")
        service.teardown(botID: botID)
    }

    func test_provisionStartsStoppedContainerInsteadOfRecreating() throws {
        // WHY: Stop then Send used to rm+create, wiping apt packages and the port.
        let support = makeSupport("rc-guest-restart")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        _ = try service.provision(botID: botID)
        let name = BotComputerGuestSpec.containerName(botID: botID)
        try service.stop(botID: botID)
        XCTAssertEqual(fake.stopped, [name])
        fake.created.removeAll()
        let ready = try service.provision(botID: botID)
        XCTAssertTrue(ready.resumed)
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertTrue(fake.started.contains(name))
        XCTAssertFalse(fake.removed.contains(name))
        service.teardown(botID: botID)
    }

    func test_execRunsAptAsRootAndOpenTerminalDetaches() throws {
        let support = makeSupport("rc-guest-exec")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        _ = try service.exec(botID: botID, command: "apt-get install -y sl")
        XCTAssertEqual(fake.lastExec?.user, "0")
        // The agent's shell runs under the guest deadline so a long apt-get is
        // stopped inside the guest, not orphaned when the host gives up.
        XCTAssertEqual(
            fake.lastExec?.command,
            BotComputerGuestSpec.execDeadlinePrefix + ["bash", "-lc", "apt-get install -y sl"]
        )
        try service.openTerminal(botID: botID)
        XCTAssertEqual(fake.lastExec?.detach, true)
        XCTAssertEqual(fake.lastExec?.command, BotComputerGuestSpec.terminalCommand())
        let rebuilt = try service.rebuild(botID: botID)
        XCTAssertEqual(rebuilt.screenURL.host, "127.0.0.1")
        XCTAssertTrue(fake.builds.contains(BotComputerGuestSpec.recipeURL(appSupport: support, botID: botID)))
        XCTAssertFalse(fake.renamed.isEmpty)
        service.teardown(botID: botID)
    }

    func test_execAfterSlowProvisioningStillAnswersBeforeTheCallerStopsWaiting() throws {
        // WHY: the MCP caller's wait starts at enqueue; provisioning a cold
        // container eats into it. The guest limit is sized at exec start so the
        // host's own deadline (guest + kill grace + docker slack + result margin)
        // still lands before the caller's deadline.
        let support = makeSupport("rc-guest-exec-budget")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        fake.startDelay = 1.2
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        let deadline = Date().addingTimeInterval(30)
        _ = try service.exec(botID: botID, command: "make", deadline: deadline)
        let command = try XCTUnwrap(fake.lastExec?.command)
        let guest = try XCTUnwrap(BotComputerGuestSpec.execGuestSeconds(inExecArguments: command))
        let issuedAt = try XCTUnwrap(fake.lastExecAt)
        XCTAssertLessThan(guest, BotComputerGuestSpec.execGuestDeadlineSeconds)
        XCTAssertLessThanOrEqual(
            issuedAt.addingTimeInterval(
                BotComputerGuestSpec.execHostDeadline(guestSeconds: guest)
                    + TimeInterval(BotComputerGuestSpec.execResultMarginSeconds)
            ),
            deadline
        )
        service.teardown(botID: botID)
    }

    func test_execWithNoBudgetLeftAfterProvisioningIsRefusedWithoutRunning() throws {
        // WHY: starting a command the caller can no longer hear about is the
        // failure this guards against; say so instead of running it blind.
        let support = makeSupport("rc-guest-exec-no-budget")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: fake,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        let botID = BotID()
        XCTAssertThrowsError(
            try service.exec(botID: botID, command: "make", deadline: Date().addingTimeInterval(8))
        ) { error in
            XCTAssertEqual(error as? BotComputerError, .invalid(BotComputerGuestService.execBudgetExhaustedMessage))
        }
        XCTAssertNil(
            fake.lastExec.flatMap { BotComputerGuestSpec.execGuestSeconds(inExecArguments: $0.command) },
            "the agent command never reached docker"
        )
        service.teardown(botID: botID)
    }

    func test_prepareHomeMigratesCustomizedLegacyRecipeWithoutLosingIt() throws {
        // WHY: existing bots already have an editable computer/Dockerfile. Moving the
        // recipe to the guest-home root must preserve that per-bot customization.
        let support = makeSupport("rc-guest-recipe-migration")
        defer { try? FileManager.default.removeItem(at: support) }
        let botID = BotID()
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID)
        let legacy = home.appendingPathComponent("computer", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let customized = "FROM debian:bookworm-slim\nRUN echo customized\n"
        try customized.write(
            to: legacy.appendingPathComponent("Dockerfile"),
            atomically: true,
            encoding: .utf8
        )

        let service = BotComputerGuestService(
            appSupport: support,
            docker: FakeDocker(),
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        try service.prepareHome(botID: botID)

        XCTAssertEqual(
            try String(contentsOf: home.appendingPathComponent("Dockerfile"), encoding: .utf8),
            customized,
            "migration must keep the bot's edited Dockerfile byte-for-byte"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Dockerfile").path),
            "the active Dockerfile must no longer appear under a misleading computer folder"
        )
        for name in ["start.sh", "embed.html", "launch-browser.sh"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path),
                "the root build context must keep every file referenced by Dockerfile"
            )
        }
    }

    func test_prepareHomeUpgradesOnlyTheKnownUnauthenticatedStartScript() throws {
        // WHY: shipped recipes must gain TokenFile admission after upgrade,
        // while an explicitly edited start script remains the user's choice.
        let support = makeSupport("rc-guest-start-auth-migration")
        defer { try? FileManager.default.removeItem(at: support) }
        let botID = BotID()
        let home = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: botID)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let legacy = """
        #!/bin/bash
        set -eu
        export DISPLAY="${DISPLAY:-:1}"
        export HOME="${HOME:-/home/remotecode}"
        mkdir -p "$HOME/.browser-profiles/chromium" /tmp/fluxbox
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true

        Xvfb :1 -screen 0 1280x800x24 -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if xdpyinfo -display :1 >/dev/null 2>&1; then
                break
            fi
            sleep 0.2
        done
        xdpyinfo -display :1 >/dev/null

        fluxbox -display :1 -log /tmp/fluxbox.log >/tmp/fluxbox.out 2>&1 &
        /opt/remotecode-computer/launch-browser.sh || xterm -display :1 &

        # Guest VNC stays loopback. Docker NAT publishes 6080 on 127.0.0.1 of the host.
        x11vnc -display :1 -rfbport 5900 -localhost -forever -shared -nopw \\
            >/tmp/x11vnc.log 2>&1 &

        websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 \\
            >/tmp/websockify.log 2>&1 &

        wait -n
        exit 1
        """ + "\n"
        let legacyDigest = SHA256.hash(data: Data(legacy.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            legacyDigest,
            "fc19d6b61e02c4ee713dde41886f4dfbae6d8631ce990dbd045f36eced478d8e",
            "the migration fixture must stay byte-identical to recipe revision 2"
        )
        let start = home.appendingPathComponent("start.sh")
        try legacy.write(to: start, atomically: true, encoding: .utf8)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = BotComputerGuestService(
            appSupport: support,
            docker: FakeDocker(),
            recipeContext: repository.appendingPathComponent(
                "Sources/AppShell/Resources/ComputerGuest",
                isDirectory: true
            )
        )

        try service.prepareHome(botID: botID)

        let migrated = try String(contentsOf: start, encoding: .utf8)
        XCTAssertTrue(migrated.contains("--token-plugin TokenFile"))
        XCTAssertTrue(migrated.contains("REMOTECODE_VIEWER_TOKEN"))
    }

    private final class SleepCounter: @unchecked Sendable {
        var count = 0
    }

    private final class ReconciliationWorkerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let completed = DispatchSemaphore(value: 0)
        private var mainThread = false

        func record(ranOnMainThread: Bool) {
            lock.lock()
            mainThread = ranOnMainThread
            lock.unlock()
            completed.signal()
        }

        func wait(timeout: TimeInterval) -> Bool {
            completed.wait(timeout: .now() + timeout) == .success
        }

        var ranOnMainThread: Bool {
            lock.lock()
            defer { lock.unlock() }
            return mainThread
        }
    }

    func test_ensureImageRebuildsAnImageWithTheRightRevisionButAnotherRecipe() throws {
        // WHY: another build on the same daemon left an image under this tag and
        // revision label from a different recipe (no Node 24, no Playwright MCP,
        // no CDP). Trusting tag + revision would run every bot on it.
        let support = makeSupport("rc-guest-foreign-image")
        defer { try? FileManager.default.removeItem(at: support) }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let fake = FakeDocker()
        fake.imageDigests[BotComputerGuestSpec.imageTag] = "built-from-another-recipe"
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, recipeContext: recipe,
            observeAttempts: 1, observeDelay: 0
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe])
        XCTAssertEqual(
            fake.imageDigests[BotComputerGuestSpec.imageTag],
            BotComputerGuestSpec.recipeDigest(context: recipe)
        )
        XCTAssertTrue(service.proveReady())
        XCTAssertEqual(fake.builds, [recipe], "an image built from this recipe is reused, not rebuilt every time")
    }

    func test_rebuildStopsTheOldContainerBeforeTheNewOneStarts() throws {
        // WHY: both containers bind the same home, and start.sh clears
        // Chromium's profile lock. Two running at once means two Chromiums
        // writing one profile, which corrupts the bot's cookies and logins.
        let support = makeSupport("rc-guest-rebuild-order")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: BotVMRunRegistry()
        )
        let botID = BotID()
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let next = BotComputerGuestSpec.nextContainerName(botID: botID)
        _ = try service.provision(botID: botID)
        fake.lifecycle.removeAll()

        _ = try service.rebuild(botID: botID)

        let stop = try XCTUnwrap(fake.lifecycle.firstIndex(of: "stop:\(canonical)"))
        let start = try XCTUnwrap(fake.lifecycle.firstIndex(of: "start:\(next)"))
        XCTAssertLessThan(stop, start)
        XCTAssertEqual(fake.containers[canonical]?.running, true)
    }

    func test_rebuildThatNeverGetsReadyBringsTheOldContainerBack() throws {
        // WHY: the old container is stopped before the new one starts; a new
        // desktop that never proves its screen must not leave the bot with none.
        let support = makeSupport("rc-guest-rebuild-rollback")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: BotVMRunRegistry()
        )
        let botID = BotID()
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        let next = BotComputerGuestSpec.nextContainerName(botID: botID)
        _ = try service.provision(botID: botID)
        fake.lifecycle.removeAll()
        fake.execError = BotComputerGuestError.observeFailed

        XCTAssertThrowsError(try service.rebuild(botID: botID))

        XCTAssertNil(fake.containers[next], "the unready replacement is removed")
        XCTAssertEqual(fake.lifecycle.last, "start:\(canonical)")
        XCTAssertEqual(fake.containers[canonical]?.running, true)
    }

    func test_rebuildHoldsTheBotSoASendDuringTheBuildQueuesAndDrainsAfter() throws {
        // WHY: `docker build` takes minutes. A run that starts on the old
        // container meanwhile would have it stopped under it; it must queue
        // behind the rebuild and be started once the rebuild lets go.
        let support = makeSupport("rc-guest-rebuild-claim")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let registry = BotVMRunRegistry()
        let center = NotificationCenter()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            notificationCenter: center, vmRuns: registry
        )
        let botID = BotID()
        let sender = AgentThreadID()
        var drained: [AgentThreadID] = []
        let token = center.addObserver(forName: .botVMRebuildReleased, object: nil, queue: nil) { note in
            if let thread = note.userInfo?[BotHostNotificationKey.threadID] as? AgentThreadID { drained.append(thread) }
        }
        defer { center.removeObserver(token) }
        var refusedBy: BotVMRunRegistry.Entry?
        fake.onBuild = {
            refusedBy = registry.tryBegin(botID: botID, entry: .init(
                threadID: sender, runID: AgentRunID(), title: "Deploy", workspace: ""
            ))
            XCTAssertNotNil(registry.busyMessage(botID: botID, threadID: sender))
            registry.addWaiting(botID: botID, threadID: sender)
        }

        _ = try service.rebuild(botID: botID)

        XCTAssertEqual(refusedBy?.title, BotComputerGuestService.rebuildClaimTitle)
        XCTAssertNil(registry.active(botID: botID), "the rebuild lets go of the bot")
        XCTAssertEqual(drained, [sender])
        XCTAssertTrue(registry.waitingThreads(botID: botID).isEmpty)
    }

    func test_rebuildAbortsWhenAnotherRunTookTheBotDuringTheBuild() throws {
        // WHY: the holding thread's own agent may rebuild, but if that run ends
        // during the build and another thread's run starts, the old container
        // now hosts that run and must not be stopped under it.
        let support = makeSupport("rc-guest-rebuild-recheck")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let registry = BotVMRunRegistry()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: registry
        )
        let botID = BotID()
        let canonical = BotComputerGuestSpec.containerName(botID: botID)
        _ = try service.provision(botID: botID)
        let holder = AgentThreadID()
        let holderRun = AgentRunID()
        registry.begin(botID: botID, entry: .init(threadID: holder, runID: holderRun, title: "Fix CI", workspace: ""))
        let other = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Deploy", workspace: "")
        fake.onBuild = {
            registry.end(botID: botID, runID: holderRun)
            XCTAssertNil(registry.tryBegin(botID: botID, entry: other))
        }
        fake.stopped.removeAll()

        XCTAssertThrowsError(try service.rebuild(botID: botID, requestingThreadID: holder)) {
            XCTAssertEqual($0 as? BotComputerGuestServiceError, .rebuildWhileRunActive(threadTitle: "Deploy"))
        }
        XCTAssertFalse(fake.stopped.contains(canonical))
        XCTAssertEqual(fake.containers[canonical]?.running, true)
        XCTAssertNil(fake.containers[BotComputerGuestSpec.nextContainerName(botID: botID)])
        XCTAssertEqual(registry.active(botID: botID), other)
    }

    func test_provisionByTheHoldingThreadReplacesAnOutdatedContainer() throws {
        // WHY: an in-guest agent's run claims the bot before it provisions.
        // Counting its own claim as "busy" would keep a container without the
        // agent-kit bind or host alias, where that agent cannot start.
        let support = makeSupport("rc-guest-runtime-requester")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let registry = BotVMRunRegistry()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: registry
        )
        let botID = BotID()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let holder = AgentThreadID()
        registry.begin(botID: botID, entry: .init(threadID: holder, runID: AgentRunID(), title: "Fix CI", workspace: ""))
        fake.containers[name] = BotComputerContainerInspect(
            running: true, imageID: "img", hostPort: 49152,
            labels: [BotComputerGuestSpec.workspacesLabelKey: BotComputerGuestSpec.workspacesLabel([])]
        )

        XCTAssertTrue(try service.provision(botID: botID).resumed, "another caller keeps the holder's container")
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertFalse(try service.provision(botID: botID, requestingThreadID: holder).resumed)
        XCTAssertEqual(fake.created, [name])
        XCTAssertEqual(fake.createdOptions.last?.labels[BotComputerGuestSpec.runtimeLabelKey], BotComputerGuestSpec.runtimeRevision)
    }

    func test_containerFromAnOlderImageIsKeptWhileAnotherRunHoldsTheBot() throws {
        // WHY: a rebuilt per-bot or base image must not swap the container
        // out from under a run; it is applied once the bot is idle.
        let support = makeSupport("rc-guest-image-busy")
        defer { try? FileManager.default.removeItem(at: support) }
        let fake = FakeDocker()
        let registry = BotVMRunRegistry()
        let service = BotComputerGuestService(
            appSupport: support, docker: fake, observeAttempts: 1, observeDelay: 0,
            vmRuns: registry
        )
        let botID = BotID()
        let name = BotComputerGuestSpec.containerName(botID: botID)
        let run = AgentRunID()
        registry.begin(botID: botID, entry: .init(threadID: AgentThreadID(), runID: run, title: "Fix CI", workspace: ""))
        fake.containers[name] = BotComputerContainerInspect(
            running: true, imageID: "older-image", hostPort: 49152,
            labels: [
                BotComputerGuestSpec.workspacesLabelKey: BotComputerGuestSpec.workspacesLabel([]),
                BotComputerGuestSpec.runtimeLabelKey: BotComputerGuestSpec.runtimeRevision,
            ]
        )

        XCTAssertTrue(try service.provision(botID: botID).resumed)
        XCTAssertTrue(fake.removed.isEmpty)
        registry.end(botID: botID, runID: run)
        XCTAssertFalse(try service.provision(botID: botID).resumed)
        XCTAssertEqual(fake.removed, [name])
    }

    private func makeSupport(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
