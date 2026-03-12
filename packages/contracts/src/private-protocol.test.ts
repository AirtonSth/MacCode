/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import {
	isDesktopMobileConnectQrPayload,
	parseDesktopMobileConnectQrPayload,
} from "./private-protocol";

describe("private-protocol QR payload helpers", () => {
	test("accepts a valid desktop mobile connect QR payload", () => {
		const payload = {
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_123",
			connectorName: "Studio MacBook",
			type: "remotecode_private_mobile_connect" as const,
			version: 1 as const,
		};

		expect(isDesktopMobileConnectQrPayload(payload)).toBe(true);
		expect(parseDesktopMobileConnectQrPayload(JSON.stringify(payload))).toEqual(payload);
	});

	test("rejects an invalid desktop mobile connect QR payload", () => {
		expect(isDesktopMobileConnectQrPayload({ type: "other" })).toBe(false);
		expect(() => parseDesktopMobileConnectQrPayload(JSON.stringify({ type: "other" }))).toThrow(
			"invalid_private_mobile_qr_payload",
		);
	});
});
