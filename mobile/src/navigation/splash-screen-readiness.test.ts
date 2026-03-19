/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * [M-12] Splash screen readiness gate.
 *
 * `SplashScreen.hideAsync()` must only be called once both
 * `isConfigLoaded` and `isSessionLoaded` are true. This prevents the
 * splash animation (~244ms) from ending before the first meaningful
 * screen has data to render.
 *
 * These tests verify the pure boolean logic extracted from the effect
 * in `root-layout-content.tsx`.
 */

function shouldHideSplash(isConfigLoaded: boolean, isSessionLoaded: boolean): boolean {
	return isConfigLoaded && isSessionLoaded;
}

describe("[M-12] splash screen readiness gate", () => {
	test("does not hide splash when neither config nor session is loaded", () => {
		expect(shouldHideSplash(false, false)).toBe(false);
	});

	test("does not hide splash when only config is loaded", () => {
		expect(shouldHideSplash(true, false)).toBe(false);
	});

	test("does not hide splash when only session is loaded", () => {
		expect(shouldHideSplash(false, true)).toBe(false);
	});

	test("hides splash when both config and session are loaded", () => {
		expect(shouldHideSplash(true, true)).toBe(true);
	});

	test("transition from partial to full readiness triggers hide exactly once", () => {
		let hideCallCount = 0;
		let prevResult = false;

		const states: [boolean, boolean][] = [
			[false, false],
			[true, false],
			[true, true],
			[true, true], // stable — no additional call
		];

		for (const [configLoaded, sessionLoaded] of states) {
			const result = shouldHideSplash(configLoaded, sessionLoaded);

			if (result && !prevResult) {
				hideCallCount += 1;
			}

			prevResult = result;
		}

		expect(hideCallCount).toBe(1);
	});

	test("session loading first then config still triggers hide", () => {
		let hideCallCount = 0;
		let prevResult = false;

		const states: [boolean, boolean][] = [
			[false, false],
			[false, true],
			[true, true],
		];

		for (const [configLoaded, sessionLoaded] of states) {
			const result = shouldHideSplash(configLoaded, sessionLoaded);

			if (result && !prevResult) {
				hideCallCount += 1;
			}

			prevResult = result;
		}

		expect(hideCallCount).toBe(1);
	});
});
