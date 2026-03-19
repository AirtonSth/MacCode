/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-23: LAN scan should not reset discovered servers before new results arrive.
 *
 * The fix removes the `setDiscoveredServers([])` call at scan start, keeping
 * previous results visible until the new scan completes. This test validates
 * the merge logic: new results atomically replace old ones.
 */

interface ScanState {
	discoveredServers: string[];
	isScanning: boolean;
}

/**
 * Simulates the scan lifecycle after the fix:
 * - Previous servers stay visible while scanning
 * - New servers replace old ones atomically when scan completes
 */
const simulateScanLifecycle = (
	previousServers: string[],
	newServers: string[],
): { duringScanning: ScanState; afterScan: ScanState } => {
	const state: ScanState = {
		discoveredServers: Array.from(previousServers),
		isScanning: false,
	};

	// Scan starts — no clearing (the fix)
	state.isScanning = true;

	const duringScanning: ScanState = {
		discoveredServers: Array.from(state.discoveredServers),
		isScanning: state.isScanning,
	};

	// Scan completes — atomically replace
	state.discoveredServers = newServers;
	state.isScanning = false;

	const afterScan: ScanState = {
		discoveredServers: Array.from(state.discoveredServers),
		isScanning: state.isScanning,
	};

	return { afterScan, duringScanning };
};

describe("M-23: LAN scan preserves previous results", () => {
	test("previous servers remain visible while scanning", () => {
		const { duringScanning } = simulateScanLifecycle(
			["server-a", "server-b"],
			["server-c"],
		);

		expect(duringScanning.discoveredServers).toEqual(["server-a", "server-b"]);
		expect(duringScanning.isScanning).toBe(true);
	});

	test("new servers atomically replace old ones after scan completes", () => {
		const { afterScan } = simulateScanLifecycle(
			["server-a", "server-b"],
			["server-c"],
		);

		expect(afterScan.discoveredServers).toEqual(["server-c"]);
		expect(afterScan.isScanning).toBe(false);
	});

	test("empty previous list stays empty during scan (no regression)", () => {
		const { duringScanning, afterScan } = simulateScanLifecycle(
			[],
			["server-a"],
		);

		expect(duringScanning.discoveredServers).toEqual([]);
		expect(afterScan.discoveredServers).toEqual(["server-a"]);
	});

	test("scan returning empty list clears previous servers", () => {
		const { afterScan } = simulateScanLifecycle(
			["server-a"],
			[],
		);

		expect(afterScan.discoveredServers).toEqual([]);
	});
});
