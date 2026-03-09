import { expect, test } from "bun:test";

import {
	getPrivateAccountStatusLabel,
	serializePrivateAccountQrPayload,
} from "./private-account-sidebar-footer";

test("getPrivateAccountStatusLabel returns signed-out copy when no session exists", () => {
	expect(getPrivateAccountStatusLabel(null)).toBe("Sign in");
});

test("getPrivateAccountStatusLabel reflects relay state for authenticated users", () => {
	expect(getPrivateAccountStatusLabel({
		authenticated: true,
		connector: null,
		connectorRelayState: "connected",
		errorMessage: null,
		qrPayload: null,
		user: {
			email: "dev@example.com",
			id: "usr_1",
		},
	})).toBe("Relay online");
});

test("serializePrivateAccountQrPayload returns stable JSON for QR generation", () => {
	expect(serializePrivateAccountQrPayload({
		authenticated: true,
		connector: null,
		connectorRelayState: "connected",
		errorMessage: null,
		qrPayload: {
			backendUrl: "http://127.0.0.1:8787",
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			type: "remotecode_private_mobile_connect",
			version: 1,
		},
		user: {
			email: "dev@example.com",
			id: "usr_1",
		},
	})).toContain("\"connectorId\":\"con_1\"");
});

