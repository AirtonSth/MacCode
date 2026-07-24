import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import CoreModel
@testable import SocketServer
@testable import Persistence
@testable import Surfaces

/// Intent: v2 must be packaged as RemoteCode, with the legacy desktop
/// bundle identifier and icon, so users can install it as an update.
@MainActor
final class AppIdentityNotificationTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    func testReleaseChannelUsesLegacyRemoteCodeDesktopIdentity() {
        XCTAssertEqual(ReleaseChannel.stable.bundleID, "io.remotecode.desktop")
        XCTAssertEqual(ReleaseChannel.stable.displayName, "RemoteCode")
        XCTAssertEqual(ReleaseChannel.debug.displayName, "RemoteCodeDebug")
    }

    func testPackageScriptBuildsRemoteCodeAppWithLegacyIcon() throws {
        let script = try String(contentsOf: packageScriptURL())

        XCTAssertTrue(script.contains("BUNDLE=\"RemoteCode.app\""))
        XCTAssertTrue(script.contains("BUNDLE_ID=\"${RC2_BUNDLE_ID:-io.remotecode.desktop}\""))
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key><string>RemoteCode</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleDocumentTypes</key>"))
        XCTAssertTrue(script.contains("<string>public.folder</string>"),
                      "dragging a Finder folder onto the Dock app icon must route that folder to NSApplication open-file handling")
        XCTAssertTrue(script.contains("AppIcon.icns"))
        XCTAssertTrue(script.contains("DISTILL_SERVICE=\"$BIN_DIR/RemoteCodeDistillService\""),
                      "packaging must require the Token Saver sidecar executable")
        XCTAssertTrue(script.contains("Contents/MacOS/RemoteCodeDistillService"),
                      "RemoteCode.app must contain the sidecar so Bundle.main can resolve it without global installs")
        XCTAssertTrue(script.contains("SCHEDULED_TASK_AGENT=\"$BIN_DIR/RemoteCodeScheduledTaskAgent\""),
                      "packaging must require a supplemental Scheduled Tasks agent executable")
        XCTAssertTrue(script.contains("Contents/Resources/RemoteCodeScheduledTaskAgent"),
                      "the LaunchAgent must not launch the GUI app executable directly because ServiceManagement rejects its launch category")
        XCTAssertTrue(script.contains("codesign --force --sign \"$CODESIGN_IDENTITY\" --timestamp=none \"$STAGING_APP/Contents/Resources/RemoteCodeScheduledTaskAgent\""),
                      "local packaging must explicitly sign the supplemental agent with the durable CODESIGN_IDENTITY")
        XCTAssertTrue(script.contains("<key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>"),
                      "release bundles must point Sparkle at the stable appcast feed")
        XCTAssertTrue(script.contains("SPARKLE_FEED_URL=\"${RC2_SPARKLE_FEED_URL:-https://remotecode.io/downloads/macos/appcast.xml}\""),
                      "default release bundles must use the public S3-backed appcast instead of release-hosted assets")
        XCTAssertTrue(script.contains("<key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>"),
                      "release bundles must embed the Sparkle EdDSA public key used to verify update archives")
        XCTAssertTrue(script.contains("<key>SUEnableAutomaticChecks</key><true/>"),
                      "auto-update must enable Sparkle background update checks")
        XCTAssertTrue(script.contains("<key>SUAutomaticallyUpdate</key><false/>"),
                      "RemoteCode must not silently install and relaunch while sessions are active; Sparkle should ask before installing")
        XCTAssertTrue(script.contains("Contents/Frameworks/Sparkle.framework"),
                      "the SwiftPM-built app bundle must embed Sparkle.framework for the updater to load")
        XCTAssertTrue(script.contains("install_name_tool -add_rpath \"@executable_path/../Frameworks\""),
                      "the packaged executable must be able to find embedded Sparkle.framework")
        XCTAssertTrue(script.contains("RC2_PACKAGE_APP_OUTPUT"),
                      "DMG and test packaging must be able to build into a staging app without touching the live dev bundle")
        XCTAssertTrue(script.contains("STAGING_APP"),
                      "local packaging must assemble and sign a staging bundle before swapping the final app path")
        XCTAssertTrue(script.contains("codesign --force --deep --sign - --timestamp=none \"$STAGING_APP\""),
                      "local packaging must ad-hoc sign after rpath changes so the app can launch for smoke tests")
        XCTAssertTrue(script.contains("codesign --verify --deep --strict --verbose=2 \"$STAGING_APP\""),
                      "local packaging must verify the staged signature before replacing the final app")
        XCTAssertTrue(script.contains("refusing to replace running $APP_PATH"),
                      "local packaging must fail loud instead of overwriting a live bundle and letting macOS kill the mapped executable with Code Signature Invalid")
        XCTAssertTrue(script.contains("RC2_REPLACE_RUNNING_APP"),
                      "only explicit relaunch callers may stop and replace a running local dev app")
        let refusal = try XCTUnwrap(script.range(of: "refusing to replace running $APP_PATH"))
        let replace = try XCTUnwrap(script.range(of: "rm -rf \"$APP_PATH\""))
        XCTAssertLessThan(refusal.lowerBound, replace.lowerBound,
                          "the live-bundle refusal must run before the destructive final app replacement")
    }

    func testReleaseWorkflowPublishesSignedSparkleAppcastToS3() throws {
        let workflow = try String(contentsOf: releaseWorkflowURL())

        XCTAssertTrue(workflow.contains("RC2_SPARKLE_PUBLIC_ED_KEY"),
                      "release packaging must receive the Sparkle public key from secrets")
        XCTAssertTrue(workflow.contains("SPARKLE_PRIVATE_KEY"),
                      "the appcast must be signed with the private EdDSA key in CI")
        XCTAssertTrue(workflow.contains("sign_update"),
                      "the release workflow must use Sparkle tooling to sign the DMG enclosure")
        XCTAssertTrue(workflow.contains("dist/pages/appcast.xml"),
                      "the release workflow must generate the appcast that Sparkle polls")
        XCTAssertTrue(workflow.contains("assume-role-with-web-identity"),
                      "release CI must assume the AWS role before publishing public artifacts to the private frontend bucket")
        XCTAssertFalse(workflow.contains("--acl public-read"),
                       "release uploads must rely on CloudFront OAC instead of public ACLs because the frontend bucket blocks public ACLs")
        XCTAssertTrue(workflow.contains("s3://$S3_BUCKET/$S3_DOWNLOAD_PREFIX/$TAG/$ASSET_NAME"),
                      "the notarized DMG must be copied to a versioned S3 key so Sparkle does not depend on private GitHub release URLs")
        XCTAssertTrue(workflow.contains("s3://$S3_BUCKET/$S3_DOWNLOAD_PREFIX/appcast.xml"),
                      "the signed appcast must be published to the public S3-backed feed URL")
        XCTAssertTrue(workflow.contains("export RC2_SPARKLE_FEED_URL=\"$S3_DOWNLOAD_BASE_URL/appcast.xml\""),
                      "packaged release bundles must embed the public S3-backed appcast URL")
        XCTAssertTrue(workflow.contains("DMG_URL=\"$S3_DOWNLOAD_BASE_URL/$TAG/$ASSET_NAME\""),
                      "Sparkle enclosures must point at the public versioned S3 DMG URL")
        XCTAssertTrue(workflow.contains("stable-macos-arm64-RemoteCode.dmg"),
                      "the appcast must keep referencing the notarized release DMG asset")
    }

    func testSidebarActionsKeepRequestedOrderAndWorkspaceFontSize() throws {
        let source = try String(contentsOf: sidebarViewURL())
        let account = try XCTUnwrap(source.range(of: "if vm.privateAccountUser != nil"))
        let settings = try XCTUnwrap(source.range(of: "Button(action: onOpenSettings)"))
        let toggle = try XCTUnwrap(source.range(of: "Button { vm.toggleSidebar() }"))
        let newWorkspace = try XCTUnwrap(source.range(of: "title: \"New Workspace\""))
        let updates = try XCTUnwrap(source.range(of: "title: vm.updateActionTitle"))

        XCTAssertLessThan(account.lowerBound, settings.lowerBound,
                          "logged-in account avatar must stay directly before Settings in the sidebar header")
        XCTAssertLessThan(settings.lowerBound, toggle.lowerBound,
                          "Settings must stay as the cog icon directly before the sidebar toggle")
        XCTAssertLessThan(newWorkspace.lowerBound, updates.lowerBound,
                          "the update/check action belongs below Settings, not above New Workspace")
        XCTAssertTrue(source.contains("Text(title)\n                .font(DS.Font.body)"),
                      "sidebar action labels must use the same base font size as normal workspace rows")
        XCTAssertFalse(source.contains("sidebarActionRow(symbol: \"gearshape\", title: \"Settings\")"),
                       "Settings must not move back into the full-width action row area")
    }

    func testSidebarLiquidGlassAvoidsOpaqueBottomBand() throws {
        let source = try String(contentsOf: sidebarViewURL())

        XCTAssertTrue(source.contains("container.material = .sidebar"),
                      "the main sidebar should use the macOS sidebar vibrancy material for a stronger glass surface")
        XCTAssertFalse(source.contains(".background(DS.Palette.surface.opacity(0.42))"),
                       "the account footer must not repaint the bottom as a dark block after hide/show restores the sidebar")
    }

    func testSidebarWorkspaceFilterStaysVisibleWithoutAutofocus() throws {
        let source = try String(contentsOf: sidebarViewURL())

        XCTAssertTrue(source.contains("if !vm.workspaces.isEmpty {\n                workspaceFilterField"),
                      "the Workspaces filter must stay visible for normal short workspace lists, not only after the list grows past an arbitrary count")
        XCTAssertFalse(source.contains("vm.workspaces.count > 6"),
                       "the Workspaces filter must not disappear for users with only a few workspaces")
        XCTAssertTrue(source.contains("NonAutoFocusTextField("),
                      "the Workspaces filter must keep manual focus behavior so opening the sidebar does not steal keyboard focus")
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"sidebar.workspaceFilter\""),
                      "the restored Workspaces filter must keep a stable accessibility identifier for UI checks")
    }

    func testThreadOutcomeNotificationContentMatchesLegacyActionablePhases() {
        XCTAssertNil(RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .running
        ))

        let completed = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .completed
        )
        XCTAssertEqual(completed?.title, "Thread finished")
        XCTAssertEqual(completed?.body, "Build fix response is ready.")
        XCTAssertEqual(completed?.categoryIdentifier, "RemoteCodeThreadUpdate")
        XCTAssertEqual(completed?.userInfo["threadId"], "t1")
    }

    func testForegroundNotificationsStayInAppOnly() {
        XCTAssertEqual(SystemNotifier.presentationOptions(appIsForeground: true), [],
                       "foreground clients must update the in-app feed without showing a system push")
        XCTAssertEqual(SystemNotifier.presentationOptions(appIsForeground: false), [.banner, .list, .sound],
                       "push presentation is reserved for background or closed app states")
    }

    func testPrivateAccountLoginIsOptionalAndPersistsSessionForBackendPush() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivateAccount-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let api = RecordingPrivateAccountAPI()
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        XCTAssertEqual(vm.privateAccountStatus, "Optional",
                       "macOS private login must be optional; the host remains usable before an account is connected")

        vm.privateAccountEmail = "desktop@example.com"
        vm.privateAccountPassword = "password123"
        await vm.connectPrivateAccount()

        let stored = try XCTUnwrap(PrivateAccountSessionStore(repo: ctx.settingsRepo).load())
        XCTAssertEqual(api.loginRequests, [["email": "desktop@example.com", "password": "password123"]])
        XCTAssertEqual(stored.accessToken, "access-token")
        XCTAssertEqual(stored.user.email, "desktop@example.com")
        XCTAssertEqual(vm.privateAccountStatus, "Subscription active",
                       "a subscribed private account is what unlocks authenticated backend push delivery")
    }

    func testSamePrivateAccountPairingAutoApprovesWithoutMacPrompt() throws {
        let dir = NSTemporaryDirectory() + "RC2PrivatePairing-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let api = RecordingPrivateAccountAPI()
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        accountStore.save(api.session)
        let auth = LocalAuthAdapter(
            repo: DeviceTrustRepository(db: ctx.db),
            privateAccountStore: accountStore,
            privateAccountAPI: api
        )
        let prompted = PromptFlag()
        auth.onPairingRequest = { _ in prompted.value = true }

        // canAutoApprovePairing() (reached via createPairingRequest) blocks up to
        // 8 s on a DispatchSemaphore and asserts it is NEVER called on the main
        // thread. Production callers are HTTP listener threads, so exercise the
        // auto-approve path off the main thread; the main test thread waits.
        let resultBox = PairingResultBox()
        let created = expectation(description: "pairing request created off the main thread")
        DispatchQueue.global().async {
            resultBox.value = auth.createPairingRequest(
                deviceName: "iPhone",
                privateAccountAccessToken: "ios-access-token"
            )
            created.fulfill()
        }
        wait(for: [created], timeout: 12)
        let request = try XCTUnwrap(resultBox.value)
        let status = try XCTUnwrap(auth.pairingRequestStatus(requestId: request.requestId))

        XCTAssertFalse(prompted.value,
                       "when iOS and macOS prove the same subscribed private account, pairing must not ask the Mac user for approval")
        XCTAssertEqual(status.status, "approved")
        XCTAssertNotNil(status.token,
                        "same-account auto-approval must still mint a normal trusted-device token for later direct RPC auth")
    }

    func testPrivateAccountRefreshUsesRefreshTokenBeforeDroppingOptionalSession() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivateRefresh-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let api = RecordingPrivateAccountAPI()
        api.currentUserShouldFail = true
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(api.session)
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        await vm.refreshPrivateAccount()

        let stored = try XCTUnwrap(PrivateAccountSessionStore(repo: ctx.settingsRepo).load())
        XCTAssertEqual(api.refreshRequests, ["refresh-token"])
        XCTAssertEqual(stored.accessToken, "refreshed-access-token")
        XCTAssertEqual(vm.privateAccountStatus, "Subscription active",
                       "macOS optional private login must recover expired access tokens before discarding the account")
    }

    func testPrivateBillingPortalUsesBackendPortalAndInjectedOpener() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivatePortal-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let api = RecordingPrivateAccountAPI()
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(api.session)
        var openedURL: URL?
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api, openURL: { openedURL = $0 })

        await vm.openPrivateBillingPortal()

        XCTAssertEqual(api.billingOverviewRequests, ["access-token"])
        XCTAssertEqual(api.portalRequests, ["access-token"])
        XCTAssertEqual(openedURL?.absoluteString, "https://apps.apple.com/account/subscriptions")
        XCTAssertEqual(vm.privateBillingPortalURL?.absoluteString, "https://apps.apple.com/account/subscriptions",
                       "macOS billing management must use the private backend portal contract instead of hardcoding a provider URL")
    }

    func testDisconnectPrivateAccountLogsOutWithoutRevokingLocalPairing() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivateLogout-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let trustRepo = DeviceTrustRepository(db: ctx.db)
        let request = try trustRepo.createPairingRequest(deviceName: "iPhone", ttlSeconds: 600)
        let paired = try trustRepo.approvePairingRequest(id: request.id)
        let api = RecordingPrivateAccountAPI()
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(api.session)
        let vm = SettingsViewModel(context: ctx, privateAccountAPI: api)

        await vm.disconnectPrivateAccount()

        XCTAssertEqual(api.logoutRequests, ["refresh-token"])
        XCTAssertNil(PrivateAccountSessionStore(repo: ctx.settingsRepo).load())
        XCTAssertNotNil(try trustRepo.verify(token: paired?.token ?? ""),
                        "macOS private logout must not revoke paired iOS trusted-device credentials")
    }

    func testPrivatePushTokenUpdateStoresPairedIosTokenForBackendDelivery() throws {
        let dir = NSTemporaryDirectory() + "RC2PrivatePushToken-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let result = try router.privatePushTokenUpdate(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: "activity-token",
            deviceID: "device-1"
        )
        let stored = try XCTUnwrap(PrivatePushTargetStore(repo: ctx.settingsRepo).load())

        XCTAssertEqual(result, .object(["ok": .bool(true), "push_token_type": .string("apns")]))
        XCTAssertEqual(stored.pushToken, "apns-token")
        XCTAssertEqual(stored.liveActivityToken, "activity-token")
        XCTAssertEqual(stored.deviceId, "device-1",
                       "the Mac must retain the paired iOS APNS target before it can ask private.remotecode.io to deliver alerts")
    }

    func testPrivatePushTargetSavePreservesLiveActivityTokenWhenAlertReregistersWithoutIt() throws {
        let dir = NSTemporaryDirectory() + "RC2PushTokenPreserve-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let store = PrivatePushTargetStore(repo: ctx.settingsRepo)

        store.save(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: "start-token",
            deviceId: "device-1"
        )
        // iOS often re-registers the alert APNs token alone (Mac update / phone
        // wake). That must not erase the push-to-start Live Activity token.
        store.save(
            pushToken: "apns-token-rotated",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-1"
        )

        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(stored.pushToken, "apns-token-rotated")
        XCTAssertEqual(stored.liveActivityToken, "start-token",
                       "nil liveActivityToken on alert re-register must preserve the stored start token across Mac updates")
        XCTAssertEqual(stored.deviceId, "device-1")
    }

    func testPushToStartTokenSurvivesHostRebindAfterMacRelaunchWithoutDuplicatingRows() throws {
        let dir = NSTemporaryDirectory() + "RC2PushTokenRebind-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let store = PrivatePushTargetStore(repo: ctx.settingsRepo)

        try store.upsert(PrivatePushTargetRecord(
            deviceId: "device-1",
            serverId: "old-server-id",
            purpose: .pushToStart,
            environment: .sandbox,
            token: "start-token",
            activityGeneration: 1,
            bootEpoch: 3,
            activitySessionId: "old-server-id:3:1",
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        ))
        try store.upsert(PrivatePushTargetRecord(
            deviceId: "device-1",
            serverId: "old-server-id",
            purpose: .alert,
            environment: .sandbox,
            token: "alert-token"
        ))

        let rebound = try store.rebindDurableTokens(toHostServerId: "fresh-server-id")
        let records = try store.records()

        XCTAssertEqual(rebound.count, 1)
        XCTAssertEqual(rebound.first?.token, "start-token")
        XCTAssertEqual(rebound.first?.serverId, "fresh-server-id")
        XCTAssertEqual(Set(records.map(\.purpose)), [.alert, .pushToStart])
        XCTAssertTrue(records.allSatisfy { $0.serverId == "fresh-server-id" })
        XCTAssertTrue(records.allSatisfy { $0.bootEpoch == nil && $0.activitySessionId == nil },
                      "durable tokens must not stay pinned to a dead boot epoch after Mac update")

        // Second rebind / re-register with a new generation must replace, not stack.
        try store.upsert(PrivatePushTargetRecord(
            deviceId: "device-1",
            serverId: "fresh-server-id",
            purpose: .pushToStart,
            environment: .sandbox,
            token: "start-token-rotated",
            activityGeneration: 99,
            bootEpoch: 12,
            activitySessionId: "fresh-server-id:12:99",
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        ))
        let afterUpsert = try store.records().filter { $0.purpose == .pushToStart }
        XCTAssertEqual(afterUpsert.count, 1,
                       "push-to-start identity must exclude boot epoch so Mac updates do not orphan tokens")
        XCTAssertEqual(afterUpsert.first?.token, "start-token-rotated")
    }

    func testUpdateTokenRPCAckReturnsMacAuthoritativeOwnershipInSnakeCase() throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityOwnershipAck-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let result = try router.privatePushTokenUpdate(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: "activity-token",
            deviceID: "device-1",
            tokenPurpose: "activity_update",
            environment: "sandbox",
            serverID: "untrusted-ios-host",
            activityGeneration: 999,
            activityID: "activity-1",
            registrationRevision: 17,
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )

        let object = try XCTUnwrap(result.objectValue)
        let ownership = try XCTUnwrap(object["ownership"]?.objectValue)
        XCTAssertEqual(object["ok"], .bool(true))
        XCTAssertEqual(object["push_token_type"], .string("apns"))
        XCTAssertEqual(object["registration_revision"], .number(17))
        XCTAssertEqual(ownership["activity_id"], .string("activity-1"))
        XCTAssertNotNil(ownership["host_id"])
        XCTAssertNotNil(ownership["boot_epoch"])
        XCTAssertNotNil(ownership["activity_generation"])
        XCTAssertNotNil(ownership["activity_session_id"])
        XCTAssertNil(ownership["activityId"], "the paired-device RPC contract is canonical snake_case")
        XCTAssertNotEqual(ownership["activity_generation"], .number(999),
                          "the Mac must not acknowledge an iOS-local generation as authoritative")
    }

    func testPrivateNotificationBridgeSendsThreadOutcomeThroughBackendPush() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivateBridge-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        accountStore.save(api.session)
        targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)

        let content = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-1",
            workspaceId: "ws-1",
            title: "Build fix",
            phase: .completed
        ))
        await bridge.deliver(content)

        XCTAssertEqual(api.alertRequests.count, 1)
        XCTAssertEqual(api.alertRequests.first?.accessToken, "access-token")
        XCTAssertEqual(api.alertRequests.first?.pushToken, "apns-token")
        XCTAssertEqual(api.alertRequests.first?.idempotencyKey, "thread.thread-1.completed")
        XCTAssertEqual(api.alertRequests.first?.title, "Thread finished")
        XCTAssertEqual(api.alertRequests.first?.body, "Build fix response is ready.",
                       "terminal outcome notifications must be sent to the private backend with the paired iOS push target")
        // The push must carry routing keys so a tap opens the exact thread, not
        // the default screen. workspaceId + threadId drive AppRouter.routeIntent.
        XCTAssertEqual(api.alertRequests.first?.data["workspaceId"], "ws-1")
        XCTAssertEqual(api.alertRequests.first?.data["threadId"], "thread-1")
        XCTAssertEqual(api.alertRequests.first?.data["category"], "RemoteCodeThreadUpdate")
    }

    func testLiveActivitySnapshotContentStateMatchesOnDeviceSchemaKeys() throws {
        let updated = Date(timeIntervalSince1970: 1_800)
        let started = Date(timeIntervalSince1970: 1_500)
        let snapshot = PrivateLiveActivitySnapshot(
            title: "Release prep",
            statusLine: "1 active thread",
            preview: "Release prep",
            phase: "running",
            activeThreadCount: 1,
            updatedAt: updated,
            runStartDate: started,
            workspaceId: "ws-1",
            threadId: "t-1"
        )

        let state = snapshot.contentState()
        XCTAssertEqual(state.title, "Release prep")
        XCTAssertEqual(state.phase, "running")
        XCTAssertEqual(state.activeThreadCount, 1)
        XCTAssertEqual(state.updatedAt, 1_800)
        XCTAssertEqual(state.runStartDate, 1_500)
        XCTAssertEqual(state.petState, "coding")
        XCTAssertEqual(state.petFrame, 0)

        // The wire content-state is decoded by iOS ActivityKit directly into
        // RemoteCodeActivityAttributes.ContentState, so the JSON keys MUST be
        // exactly that struct's stored-property names. A rename on either side
        // breaks Live Activity push decode -- this pins the contract.
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertEqual(Set((json ?? [:]).keys),
                       ["title", "statusLine", "preview", "phase", "activeThreadCount", "updatedAt", "runStartDate", "workspaceId", "threadId", "petState", "petFrame"],
                       "Live Activity push content-state keys must match the on-device ContentState schema both platforms decode")
    }

    func testLiveActivityTerminalSnapshotMapsRunOutcomeAndSkipsNonTerminalPhases() {
        XCTAssertNil(PrivateLiveActivitySnapshot.terminal(threadId: "t1", title: "Build fix", phase: .running),
                     "only real run-lifecycle ends fire a terminal Live Activity push")

        let completed = PrivateLiveActivitySnapshot.terminal(threadId: "t1", title: "Build fix", phase: .completed)
        XCTAssertEqual(completed?.phase, "completed")
        XCTAssertEqual(completed?.statusLine, "Finished")
        XCTAssertEqual(completed?.activeThreadCount, 0)
        XCTAssertEqual(completed?.preview, "Build fix response is ready.")
        XCTAssertEqual(completed?.petState, "success")
        XCTAssertEqual(completed?.petFrame, 0)

        let cancelled = PrivateLiveActivitySnapshot.terminal(threadId: "t1", title: "Build fix", phase: .cancelled)
        XCTAssertEqual(cancelled?.phase, "failed",
                       "the on-device ContentState only models running/completed/failed; cancelled maps to failed")
        XCTAssertEqual(cancelled?.petState, "interrupted",
                       "a stopped run must preserve the interrupted Pet reaction instead of the generic failed fallback")
    }

    func testLiveActivityRunningSnapshotShowsLatestTurnAsMidRunHeartbeat() {
        let runStart = Date(timeIntervalSince1970: 1000)
        // A completed turn refreshes the running card with the latest assistant
        // text + a fresh timestamp so a backgrounded card shows progress instead
        // of freezing at the start snapshot until the run ends.
        let withFinal = PrivateLiveActivitySnapshot.running(
            threadId: "t1",
            workspaceId: "ws-1",
            title: "Build fix",
            finalMessage: "  Applied the patch and ran the tests.  ",
            runStartDate: runStart,
            now: Date(timeIntervalSince1970: 1200)
        )
        XCTAssertEqual(withFinal.phase, "running")
        XCTAssertEqual(withFinal.statusLine, "Working…")
        XCTAssertEqual(withFinal.preview, "Applied the patch and ran the tests.")
        XCTAssertEqual(withFinal.workspaceId, "ws-1")
        XCTAssertEqual(withFinal.threadId, "t1")
        XCTAssertEqual(withFinal.runStartDate, runStart, "elapsed-time anchor is preserved across updates")
        XCTAssertEqual(withFinal.updatedAt, Date(timeIntervalSince1970: 1200), "a fresh timestamp resets the stale timer")

        // No assistant text yet -> fall back to the thread title; long text is clamped.
        let noFinal = PrivateLiveActivitySnapshot.running(
            threadId: "t1", workspaceId: nil, title: "  ", finalMessage: nil, runStartDate: nil
        )
        XCTAssertEqual(noFinal.title, "Thread")
        XCTAssertEqual(noFinal.preview, "Thread")

        let longText = String(repeating: "x", count: 300)
        let clamped = PrivateLiveActivitySnapshot.running(
            threadId: "t1", workspaceId: nil, title: "T", finalMessage: longText, runStartDate: nil
        )
        XCTAssertEqual(clamped.preview.count, 140, "preview is clamped to keep the card glanceable")
    }

    func testPrivateNotificationBridgeSendsLiveActivityThroughBackendWhenTokenPaired() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivity-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        accountStore.save(api.session)
        targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: "activity-token", deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)

        let snapshot = try XCTUnwrap(PrivateLiveActivitySnapshot.terminal(threadId: "thread-1", title: "Build fix", phase: .completed))
        await bridge.deliverLiveActivity(snapshot: snapshot, event: .end, idempotencyKey: "activity.thread-1.end.completed")

        XCTAssertEqual(api.liveActivityRequests.count, 1)
        let req = try XCTUnwrap(api.liveActivityRequests.first)
        XCTAssertEqual(req.accessToken, "access-token")
        XCTAssertEqual(req.liveActivityToken, "activity-token")
        XCTAssertEqual(req.pushToken, "apns-token")
        XCTAssertEqual(req.event, "end")
        XCTAssertEqual(req.idempotencyKey, "activity.thread-1.end.completed",
                       "Live Activity idempotency keys must be namespaced so they never collide with the alert for the same run")
        XCTAssertEqual(req.contentState.phase, "completed")
        XCTAssertEqual(req.contentState.statusLine, "Finished")
    }

    func testPrivateNotificationBridgeSkipsLiveActivityWhenNoStartTokenPaired() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityNoTok-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        accountStore.save(api.session)
        // No liveActivityToken: there is no activity to address, so the push
        // must be skipped rather than sent with an empty token.
        targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)

        let snapshot = try XCTUnwrap(PrivateLiveActivitySnapshot.terminal(threadId: "thread-1", title: "Build fix", phase: .completed))
        await bridge.deliverLiveActivity(snapshot: snapshot, event: .end, idempotencyKey: "activity.thread-1.end.completed")

        XCTAssertTrue(api.liveActivityRequests.isEmpty,
                      "a Live Activity push with no paired start token must be skipped, not sent against a nil activity")
    }

    func testPrivateNotificationBridgeClearsTargetWhenLiveActivityBackendDropsSubscription() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityDrop-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        api.liveActivityResult = PrivatePushDeliveryResult(delivered: false, errorCode: "apns/Unregistered", shouldDropSubscription: true)
        accountStore.save(api.session)
        targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: "activity-token", deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)

        let snapshot = try XCTUnwrap(PrivateLiveActivitySnapshot.terminal(threadId: "thread-1", title: "Build fix", phase: .completed))
        await bridge.deliverLiveActivity(snapshot: snapshot, event: .end, idempotencyKey: "activity.thread-1.end.completed")

        XCTAssertNil(targetStore.load(),
                     "a backend token-drop response on the Live Activity path must clear the stale push target, mirroring the alert path")
    }

    func testPrivateNotificationBridgeRegistersTypedLiveActivityTokenWithAuthenticatedBackend() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityV2Registration-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        accountStore.save(api.session)
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "update-token", activityGeneration: 3,
            activityId: "activity-1", bootEpoch: 8,
            activitySessionId: "server-1:8:3", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )

        try await bridge.registerLiveActivityTokenV2(target)

        let request = try XCTUnwrap(api.liveActivityV2TokenRegistrations.first)
        XCTAssertEqual(request.accessToken, "access-token")
        XCTAssertEqual(request.registration.deviceId, "device-1")
        XCTAssertEqual(request.registration.environment, .sandbox)
        XCTAssertEqual(request.registration.token, "update-token")
        XCTAssertEqual(request.registration.tokenKind, .update,
                       "an ActivityKit update token must use the backend's update registry, not push-to-start")
        XCTAssertEqual(request.registration.hostId, "server-1")
        XCTAssertEqual(request.registration.bootEpoch, 8)
        XCTAssertEqual(request.registration.activityGeneration, 3)
        XCTAssertEqual(request.registration.activitySessionId, "server-1:8:3")
        XCTAssertEqual(request.registration.activityId, "activity-1")
    }

    func testPrivateNotificationBridgeAcceptsQueuedV2AckWithoutLocalTokenTombstone() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityV2Delivery-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        api.liveActivityV2Result = PrivateLiveActivityV2DeliveryAck(
            id: "outbox-1", status: "queued", attempts: 0,
            nextAttemptAt: "2026-07-14T00:30:00.000Z"
        )
        accountStore.save(api.session)
        let alert = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .alert,
            environment: .sandbox, token: "alert-token"
        )
        let start = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "start-token", activityGeneration: 3,
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(alert)
        try targetStore.upsert(start)
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run", phase: .running, activeThreadCount: 1,
            updatedAt: 900, sessionId: "server-1:8:3", hostId: "server-1",
            epoch: "8", revision: 4
        )
        let delivery = LiveActivitySyncDelivery(
            event: .start, projection: projection, activityGeneration: 3,
            idempotencyKey: "activity.server-1.8.3.4.start"
        )

        await bridge.deliverLiveActivity(delivery)

        let request = try XCTUnwrap(api.liveActivityV2Deliveries.first)
        XCTAssertEqual(request.accessToken, "access-token")
        XCTAssertEqual(request.request.activitySessionId, "server-1:8:3")
        XCTAssertEqual(request.request.deviceId, "device-1")
        XCTAssertEqual(request.idempotencyKey, "activity.server-1.8.3.4.start")
        XCTAssertEqual(try targetStore.records(), [alert, start],
                       "queued acceptance is not an immediate APNs failure; backend owns permanent-token tombstones")
    }

    func testPrivateNotificationBridgeRefreshesV2Acceptance401AndRetriesOnce() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityV2Refresh-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        api.liveActivityV2RequiresRefresh = true
        accountStore.save(api.session)
        try targetStore.upsert(PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "start-token", activityGeneration: 3,
            contractVersion: 2, capabilities: ["live_activity_v2"]
        ))
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run", phase: .running, activeThreadCount: 1,
            updatedAt: 900, sessionId: "server-1:8:3", hostId: "server-1",
            epoch: "8", revision: 1
        )

        let delivery = LiveActivitySyncDelivery(
            event: .start, projection: projection, activityGeneration: 3,
            idempotencyKey: "activity.server-1.8.3.1.start"
        )
        let target = try XCTUnwrap(try targetStore.records().first)
        let ack = try await bridge.sendLiveActivityAcceptance(LiveActivityAcceptanceRecord(
            delivery: delivery,
            target: .v2(target)
        ))

        XCTAssertEqual(api.refreshRequests, ["refresh-token"])
        XCTAssertEqual(api.liveActivityV2Deliveries.map(\.accessToken),
                       ["access-token", "refreshed-access-token"])
        XCTAssertEqual(ack.status, "queued")
    }

    func testUnrelatedV2TargetDoesNotSuppressLegacyLiveActivityFallback() async throws {
        let dir = NSTemporaryDirectory() + "RC2LiveActivityV2Fallback-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = RecordingPrivateAccountAPI()
        accountStore.save(api.session)
        targetStore.save(
            pushToken: "apns-token", pushTokenType: "apns",
            liveActivityToken: "legacy-activity-token", deviceId: "legacy-device"
        )
        try targetStore.upsert(PrivatePushTargetRecord(
            deviceId: "other-device", serverId: "other-server", purpose: .pushToStart,
            environment: .sandbox, token: "other-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        ))
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run", phase: .running, activeThreadCount: 1,
            updatedAt: 900, sessionId: "server-1:8:3", hostId: "server-1",
            epoch: "8", revision: 1
        )

        await bridge.deliverLiveActivity(LiveActivitySyncDelivery(
            event: .start, projection: projection, activityGeneration: 3,
            idempotencyKey: "activity.server-1.8.3.1.start"
        ))

        XCTAssertEqual(api.liveActivityRequests.count, 1,
                       "v2 capability on a different host must not disable this host's legacy fallback")
        XCTAssertTrue(api.liveActivityV2Deliveries.isEmpty)
    }

    func testConcurrentPush401ResponsesShareOneSessionRefreshAndRetryOnce() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivatePushRefresh-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = ConcurrentExpiryPrivateAccountAPI()
        accountStore.save(api.session)
        targetStore.save(
            pushToken: "apns-token", pushTokenType: "apns",
            liveActivityToken: nil, deviceId: "device-1"
        )
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let first = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-1", title: "First", phase: .completed
        ))
        let second = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-2", title: "Second", phase: .completed
        ))

        async let firstDelivery: Void = bridge.deliver(first)
        async let secondDelivery: Void = bridge.deliver(second)
        _ = await (firstDelivery, secondDelivery)

        XCTAssertEqual(api.refreshCallCount, 1,
                       "concurrent access-token expiry must share one refresh instead of creating a retry storm")
        XCTAssertEqual(api.successfulAlertTokens, ["refreshed-access-token", "refreshed-access-token"])
        XCTAssertEqual(accountStore.load()?.accessToken, "refreshed-access-token")
    }

    func testConcurrentPushRefreshFailureClearsSessionWithoutRetryStorm() async throws {
        let dir = NSTemporaryDirectory() + "RC2PrivatePushRefreshFailure-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let accountStore = PrivateAccountSessionStore(repo: ctx.settingsRepo)
        let targetStore = PrivatePushTargetStore(repo: ctx.settingsRepo)
        let api = ConcurrentExpiryPrivateAccountAPI(refreshFails: true)
        accountStore.save(api.session)
        targetStore.save(
            pushToken: "apns-token", pushTokenType: "apns",
            liveActivityToken: nil, deviceId: "device-1"
        )
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api)
        let first = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-1", title: "First", phase: .completed
        ))
        let second = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-2", title: "Second", phase: .completed
        ))

        async let firstDelivery: Void = bridge.deliver(first)
        async let secondDelivery: Void = bridge.deliver(second)
        _ = await (firstDelivery, secondDelivery)

        XCTAssertEqual(api.refreshCallCount, 1)
        XCTAssertNil(accountStore.load(),
                     "terminal refresh failure must clear the unusable private session")
        XCTAssertTrue(api.successfulAlertTokens.isEmpty)
    }

    func testStreamingErrorsDoNotEmitTerminalRunNotificationsBeforeFinish() async throws {
        let dir = NSTemporaryDirectory() + "RC2Notify-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .error(message: "stderr chunk")))
        let thread = AgentThread(title: "Notify once", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            guard event.kind.hasPrefix("agent.run."),
                  event.payload.objectValue?["thread_id"]?.stringValue == thread.id.value.uuidString else { return }
            events.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        _ = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: dir,
            prompt: "fail once"
        ))
        await waitAsync("fake failure emits one failed event and finishes") {
            events.contains { $0.kind == "agent.run.failed" }
                && events.contains { $0.kind == "agent.run.finished" }
        }

        XCTAssertEqual(events.filter { $0.kind == "agent.run.failed" }.count, 1,
                       "thread notifications are driven by terminal outcomes; streaming errors must not look like extra finishes")
    }

    func testAgentRunLifecycleEventsCarryAuthoritativeRunTiming() async throws {
        let dir = NSTemporaryDirectory() + "RC2RunTimingEvents-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "timed answer")))
        let thread = AgentThread(title: "Timing mirror", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            guard (event.kind == "agent.run.started" || event.kind == "agent.run.finished"),
                  event.payload.objectValue?["thread_id"]?.stringValue == thread.id.value.uuidString else { return }
            events.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let runId = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: dir,
            prompt: "time me"
        ))
        await waitAsync("run lifecycle timing events mirrored") {
            events.contains { $0.kind == "agent.run.started" }
                && events.contains { $0.kind == "agent.run.finished" }
        }

        let persisted = try XCTUnwrap(ctx.runRepo.get(id: runId))
        let expectedStartedAtMs = Int64(persisted.startedAt.timeIntervalSince1970 * 1000)
        let startedPayload = try XCTUnwrap(events.first { $0.kind == "agent.run.started" }?.payload.objectValue)
        XCTAssertEqual(startedPayload["run_id"]?.stringValue, runId.value.uuidString,
                       "mirrors need run_id to tie lifecycle events to the host run row")
        XCTAssertEqual(startedPayload["started_at_ms"]?.intValue.map(Int64.init), expectedStartedAtMs,
                       "started_at_ms must come from the persisted run row so iOS and macOS Working timers share one clock")

        let finishedPayload = try XCTUnwrap(events.first { $0.kind == "agent.run.finished" }?.payload.objectValue)
        XCTAssertEqual(finishedPayload["run_id"]?.stringValue, runId.value.uuidString)
        XCTAssertNotNil(finishedPayload["duration_ms"]?.intValue,
                        "finished events must carry host duration metadata for mirrored completed-work UI")
    }

    func testAgentMessageAppendEventsCarryDurableChatHistoryToMirrors() async throws {
        let dir = NSTemporaryDirectory() + "RC2MessageEvents-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "persisted answer")))
        let thread = AgentThread(title: "Mirror history", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind == "agent.message.appended" { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        _ = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: dir,
            prompt: "first prompt"
        ))
        await waitAsync("durable user and assistant messages are mirrored") {
            events.count >= 2
        }

        XCTAssertTrue(events.contains { event in
            guard case .object(let payload) = event.payload else { return false }
            return payload["role"] == .string("user") && payload["content"] == .string("first prompt")
        }, "the iOS mirror must receive the persisted user message, not only transient stream state")
        XCTAssertTrue(events.contains { event in
            guard case .object(let payload) = event.payload else { return false }
            return payload["role"] == .string("assistant") && payload["content"] == .string("persisted answer")
        }, "the iOS mirror must receive the persisted assistant answer before a follow-up clears live stream state")
    }

    func testHostSendTitlesPlaceholderThreadFromFullFirstUserMessage() async throws {
        let dir = NSTemporaryDirectory() + "RC2ThreadTitle-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.claude, runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok")))
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let thread = AgentThread(title: "Thread", provider: .claude, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let firstMessage = "git add commit and push all repos here with this long exact wording"
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: firstMessage,
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.title, firstMessage,
                       "if the agent/client never names a thread, the stored title must be the full first user message")
        XCTAssertEqual(AgentThreadTitle.display(firstMessage),
                       "git add commit and push all ...",
                       "display truncation must be separate from the stored full title")
    }

    func testWorktreeExecutionCreatesIsolatedCwdBeforeFirstAgentPrompt() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2WorktreeExec-" + UUID().uuidString
        let repo = NSTemporaryDirectory() + "RC2WorktreeRepo-" + UUID().uuidString
        let worktreeRoot = repo + "-agent-worktrees"
        defer {
            closeAndUnregisterAllSurfaces()
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: worktreeRoot)
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        runShell(["git", "init", "-q", "-b", "main", repo])
        runShell(["git", "-C", repo, "config", "user.email", "t@t.t"])
        runShell(["git", "-C", repo, "config", "user.name", "test"])
        try "base\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        runShell(["git", "-C", repo, "add", "README.md"])
        runShell(["git", "-C", repo, "commit", "-q", "-m", "init"])

        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = CwdCaptureRunner()
        ctx.coordinator.replaceProvider(.codex, runner: runner)
        let workspace = try router.createWorkspace(name: "repo", cwd: repo)
        let thread = try router.createAgentThread(workspace: workspace.id, title: "worktree", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        _ = try router.configureAgentThreadExecution(thread: thread.id, executionMode: .worktree, baseBranch: "main")

        _ = try await router.sendAgentMessage(thread: thread.id, text: "run isolated", provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil)
        await waitAsync("fake provider receives worktree cwd") {
            runner.lastCwd != nil
        }

        let cwd = try XCTUnwrap(runner.lastCwd)
        let restoredThread = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertNotEqual(cwd, repo)
        XCTAssertEqual(restoredThread.executionMode, .worktree)
        XCTAssertEqual(restoredThread.baseBranch, "main")
        XCTAssertEqual(restoredThread.worktreePath, cwd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd + "/README.md"),
                      "the first provider prompt must run in a real isolated git worktree, not the original workspace")
    }

    func testCodexWarningsAreNotUserVisibleErrors() {
        let warning = "[codex stderr] 2026-05-18T19:27:58Z WARN codex_core_plugins::manifest: ignoring interface.defaultPrompt"

        XCTAssertFalse(CodexRunner.shouldDisplayStderr(warning),
                       "Codex WARN stderr is diagnostic noise; showing it in the transcript makes a healthy run look broken")
        XCTAssertFalse(CodexRunner.shouldDisplayStderr("[codex stderr] Reading additional input from stdin..."),
                       "Codex stdin diagnostics are run noise, not agent progress or a user-visible error")
        XCTAssertTrue(CodexRunner.shouldDisplayStderr("[codex stderr] fatal: authentication failed"),
                      "non-warning stderr must remain visible so real failures are not hidden")
    }

    private func packageScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package-app.sh")
    }

    private func releaseWorkflowURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".gitlab-ci.yml")
    }

    private func sidebarViewURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/SidebarView.swift")
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(desc)")
    }

    private func runShell(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

private final class CwdCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let queue = DispatchQueue(label: "CwdCaptureRunner")
    private var _lastCwd: String?

    var lastCwd: String? {
        queue.sync { _lastCwd }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        queue.sync {
            _lastCwd = request.cwd
        }
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "turn-1")))
            onEvent(.event(.turnCompleted(turnId: "turn-1", finalMessage: "ok")))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class PromptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Thread-safe holder for a pairing result produced off the main thread.
private final class PairingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (requestId: String, code: String)?

    var value: (requestId: String, code: String)? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private class RecordingPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
    let session = PrivateAccountSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        user: PrivateAccountUser(
            daysRemaing: 30,
            daysRemaining: 30,
            email: "desktop@example.com",
            id: "user-1",
            subscribed: true
        )
    )
    var loginRequests: [[String: String]] = []
    var alertRequests: [(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String)] = []
    var liveActivityRequests: [(accessToken: String, event: String, contentState: PrivateLiveActivityContentState, liveActivityToken: String, pushToken: String, pushTokenType: String, idempotencyKey: String)] = []
    var liveActivityV2TokenRegistrations: [(accessToken: String, registration: PrivateLiveActivityV2TokenRegistration)] = []
    var liveActivityV2Deliveries: [(accessToken: String, request: PrivateLiveActivityV2DeliveryRequest, idempotencyKey: String)] = []
    var liveActivityResult = PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    var liveActivityV2Result = PrivateLiveActivityV2DeliveryAck(
        id: "outbox-default", status: "queued", attempts: 0, nextAttemptAt: nil
    )
    var liveActivityV2RequiresRefresh = false
    var billingOverviewRequests: [String] = []
    var portalRequests: [String] = []
    var refreshRequests: [String] = []
    var logoutRequests: [String] = []
    var currentUserShouldFail = false

    func login(email: String, password: String) async throws -> PrivateAccountSession {
        loginRequests.append(["email": email, "password": password])
        return session
    }

    func currentUser(accessToken: String) async throws -> PrivateAccountUser {
        if currentUserShouldFail {
            throw PrivateAccountAPIError.http(401)
        }
        return session.user
    }

    func refresh(refreshToken: String) async throws -> PrivateAccountSession {
        refreshRequests.append(refreshToken)
        return PrivateAccountSession(
            accessToken: "refreshed-access-token",
            refreshToken: "refreshed-refresh-token",
            user: session.user
        )
    }

    func logout(refreshToken: String) async throws {
        logoutRequests.append(refreshToken)
    }

    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        billingOverviewRequests.append(accessToken)
        return PrivateBillingOverview(
            plan: PrivateBillingOverview.Plan(
                billingPeriod: "monthly",
                priceUsd: 4.99,
                provider: "lemon_squeezy",
                trialDays: 7
            ),
            subscription: PrivateSubscriptionSnapshot(
                daysRemaing: 30,
                daysRemaining: 30,
                email: "desktop@example.com",
                endsAt: nil,
                portalUrl: "https://apps.apple.com/account/subscriptions",
                renewsAt: "2026-06-24T00:00:00.000Z",
                status: "active",
                subscribed: true,
                trialEndsAt: nil
            )
        )
    }

    func createPortal(accessToken: String) async throws -> URL {
        portalRequests.append(accessToken)
        return URL(string: "https://apps.apple.com/account/subscriptions")!
    }

    func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String, silent: Bool = false) async throws -> PrivatePushDeliveryResult {
        alertRequests.append((accessToken, title, body, data, pushToken, pushTokenType, idempotencyKey))
        return PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }

    func deliverLiveActivity(accessToken: String, event: String, contentState: PrivateLiveActivityContentState, timestampSeconds: Int64, liveActivityToken: String, pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult {
        liveActivityRequests.append((accessToken, event, contentState, liveActivityToken, pushToken, pushTokenType, idempotencyKey))
        return liveActivityResult
    }

    func registerLiveActivityTokenV2(
        accessToken: String,
        registration: PrivateLiveActivityV2TokenRegistration
    ) async throws -> PrivateLiveActivityV2TokenRegistrationAck {
        liveActivityV2TokenRegistrations.append((accessToken, registration))
        return PrivateLiveActivityV2TokenRegistrationAck(token: .init(
            activityKey: registration.activityKey,
            deviceId: registration.deviceId,
            environment: registration.environment,
            tokenKind: registration.tokenKind,
            hostId: registration.hostId,
            bootEpoch: registration.bootEpoch,
            activityGeneration: registration.activityGeneration,
            activitySessionId: registration.activitySessionId,
            activityId: registration.activityId
        ))
    }

    func deliverLiveActivityV2(
        accessToken: String,
        request: PrivateLiveActivityV2DeliveryRequest,
        idempotencyKey: String
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        liveActivityV2Deliveries.append((accessToken, request, idempotencyKey))
        if liveActivityV2RequiresRefresh, accessToken == "access-token" {
            throw PrivateAccountAPIError.http(401)
        }
        return liveActivityV2Result
    }
}

private actor TwoAttemptGate {
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        arrivalCount += 1
        if arrivalCount == 2 {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class ConcurrentExpiryPrivateAccountAPI: RecordingPrivateAccountAPI, @unchecked Sendable {
    private let gate = TwoAttemptGate()
    private let lock = NSLock()
    private let refreshFails: Bool
    private var refreshCount = 0
    private var successfulTokens: [String] = []

    var refreshCallCount: Int { lock.withLock { refreshCount } }
    var successfulAlertTokens: [String] { lock.withLock { successfulTokens.sorted() } }

    init(refreshFails: Bool = false) {
        self.refreshFails = refreshFails
        super.init()
    }

    override func refresh(refreshToken: String) async throws -> PrivateAccountSession {
        lock.withLock { refreshCount += 1 }
        if refreshFails {
            throw PrivateAccountAPIError.http(401)
        }
        return PrivateAccountSession(
            accessToken: "refreshed-access-token",
            refreshToken: "refreshed-refresh-token",
            user: session.user
        )
    }

    override func deliverAlert(
        accessToken: String,
        title: String,
        body: String,
        data: [String: String],
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String,
        silent: Bool = false
    ) async throws -> PrivatePushDeliveryResult {
        if accessToken == "access-token" {
            await gate.arrive()
            throw PrivateAccountAPIError.http(401)
        }
        lock.withLock { successfulTokens.append(accessToken) }
        return PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }
}
