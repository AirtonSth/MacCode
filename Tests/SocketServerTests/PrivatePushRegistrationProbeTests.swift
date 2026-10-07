import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY (C4): the unchanged-token short-circuit may only answer requests the
/// full path would accept and that touch nothing but the alert/legacy target.
/// Live Activity registrations also feed the coordinator's backend
/// registration, which must never be skipped.
final class PrivatePushRegistrationProbeTests: XCTestCase {
    private let alert: [String: JSONValue] = [
        "push_token": .string("apns-token"),
        "push_token_type": .string("apns"),
        "device_id": .string("device-1"),
        "token_purpose": .string("alert"),
        "environment": .string("production"),
        "server_id": .string("host-1"),
        "authenticated_host_id": .string("host-1"),
    ]

    func test_legacyAndTypedAlertAreProbed() throws {
        let legacy = try XCTUnwrap(PrivatePushRegistrationProbe.make(from: [
            "push_token": .string("apns-token"), "push_token_type": .string("apns"),
        ]))
        XCTAssertNil(legacy.alert)
        XCTAssertNil(legacy.profileBinding)
        XCTAssertEqual(legacy.result, .object(["ok": .bool(true), "push_token_type": .string("apns")]))

        let typed = try XCTUnwrap(PrivatePushRegistrationProbe.make(from: alert))
        XCTAssertEqual(typed.alert?.serverID, "host-1")
        XCTAssertEqual(typed.alert?.contractVersion, 1)
    }

    func test_liveActivityRegistrationsAreNeverProbed() {
        var v2Alert = alert
        v2Alert["contract_version"] = .number(2)
        v2Alert["capabilities"] = .array([.string("live_activity_v2")])
        XCTAssertNil(PrivatePushRegistrationProbe.make(from: v2Alert), "v2 alert also registers with the backend")

        for purpose in ["push_to_start", "activity_update"] {
            var params = alert
            params["token_purpose"] = .string(purpose)
            params["live_activity_token"] = .string("la")
            XCTAssertNil(PrivatePushRegistrationProbe.make(from: params), purpose)
        }
        for key in ["boot_epoch", "activity_generation", "activity_id", "activity_session_id"] {
            var params = alert
            params[key] = key.hasSuffix("id") ? .string("x") : .number(1)
            XCTAssertNil(PrivatePushRegistrationProbe.make(from: params), key)
        }
    }

    func test_requestsTheFullPathWouldRejectAreNeverProbed() {
        var cases: [String: [String: JSONValue]] = [:]
        cases["webpush"] = alert.merging(["push_token_type": .string("webpush")]) { $1 }
        cases["empty token"] = alert.merging(["push_token": .string("")]) { $1 }
        cases["bad environment"] = alert.merging(["environment": .string("staging")]) { $1 }
        cases["missing server"] = alert.filter { $0.key != "server_id" }
        cases["non-string capability"] = alert.merging(["capabilities": .array([.number(2)])]) { $1 }
        cases["contract 0"] = alert.merging(["contract_version": .number(0)]) { $1 }
        cases["negative revision"] = alert.merging(["registration_revision": .number(-1)]) { $1 }
        cases["blank profile"] = alert.merging(["profile_id": .string("  ")]) { $1 }
        cases["profile without host"] = alert.filter { $0.key != "authenticated_host_id" }
            .merging(["profile_id": .string("p")]) { $1 }
        cases["non-string device"] = alert.merging(["device_id": .number(1)]) { $1 }
        for (name, params) in cases {
            XCTAssertNil(PrivatePushRegistrationProbe.make(from: params), name)
        }
    }

    func test_resultEchoesRevisionAndBindingButNeverTheToken() throws {
        var params = alert
        params["registration_revision"] = .number(9)
        params["profile_id"] = .string("profile-1")
        let probe = try XCTUnwrap(PrivatePushRegistrationProbe.make(from: params))
        XCTAssertEqual(probe.result, .object([
            "ok": .bool(true),
            "push_token_type": .string("apns"),
            "registration_revision": .number(9),
            "profile_id": .string("profile-1"),
            "host_id": .string("host-1"),
            "device_id": .string("device-1"),
        ]))
    }
}
