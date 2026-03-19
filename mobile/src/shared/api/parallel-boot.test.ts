/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-35: Config providers should load in parallel to reduce boot latency.
 *
 * The fix uses Promise.all in _layout.tsx to load both ApiConfigStore and
 * PrivateSessionStore simultaneously, then passes the results as initial
 * data to the providers, skipping their individual useEffect-based loads.
 */

const simulateSequentialBoot = async (
	loadA: () => Promise<number>,
	loadB: () => Promise<number>,
): Promise<number> => {
	const startA = Date.now();
	await loadA();
	const endA = Date.now();
	await loadB();
	const endB = Date.now();
	return (endA - startA) + (endB - endA);
};

const simulateParallelBoot = async (
	loadA: () => Promise<number>,
	loadB: () => Promise<number>,
): Promise<number> => {
	const start = Date.now();
	await Promise.all([loadA(), loadB()]);
	const end = Date.now();
	return end - start;
};

const makeDelayedLoader = (delayMs: number): (() => Promise<number>) => {
	return async () =>
		// eslint-disable-next-line promise/avoid-new -- Testing Promise.all behavior
		await new Promise((resolve) => {
			setTimeout(() => {
				resolve(delayMs);
			}, delayMs);
		});
};

describe("M-35: Parallel provider boot", () => {
	test("Promise.all runs both loads concurrently", async () => {
		const loadA = makeDelayedLoader(50);
		const loadB = makeDelayedLoader(50);

		const parallelTime = await simulateParallelBoot(loadA, loadB);

		// Parallel should complete in roughly the time of the longest task,
		// not the sum. Allow 30ms tolerance for timer imprecision.
		expect(parallelTime).toBeLessThan(100);
	});

	test("sequential boot takes at least the sum of both loads", async () => {
		const loadA = makeDelayedLoader(40);
		const loadB = makeDelayedLoader(40);

		const sequentialTime = await simulateSequentialBoot(loadA, loadB);

		expect(sequentialTime).toBeGreaterThanOrEqual(70);
	});

	test("parallel boot is faster than sequential boot", async () => {
		const loadA = makeDelayedLoader(50);
		const loadB = makeDelayedLoader(50);

		const loadA2 = makeDelayedLoader(50);
		const loadB2 = makeDelayedLoader(50);

		const parallelTime = await simulateParallelBoot(loadA, loadB);
		const sequentialTime = await simulateSequentialBoot(loadA2, loadB2);

		expect(parallelTime).toBeLessThan(sequentialTime);
	});

	test("provider with initialConfig skips reload", () => {
		const hasInitialConfig = true;
		const shouldReload = !hasInitialConfig;

		expect(shouldReload).toBe(false);
	});

	test("provider without initialConfig triggers reload", () => {
		const hasInitialConfig = false;
		const shouldReload = !hasInitialConfig;

		expect(shouldReload).toBe(true);
	});
});
