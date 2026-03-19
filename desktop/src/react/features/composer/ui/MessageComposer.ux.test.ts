/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const composerSource = readFileSync(resolve(__dirname, "MessageComposer.tsx"), "utf-8");

describe("[D-29] Status text crossfade transition", () => {
	it("applies an inline opacity transition style to the status text span", () => {
		expect(composerSource).toContain('transition: "opacity 200ms ease"');
	});

	it("the status text span still uses aria-live polite for accessibility", () => {
		const ariaLiveBlock = composerSource.indexOf('aria-live="polite"');
		const transitionBlock = composerSource.indexOf('transition: "opacity 200ms ease"');
		expect(ariaLiveBlock).toBeGreaterThan(-1);
		expect(transitionBlock).toBeGreaterThan(-1);
		// The transition should be within the aria-live region
		expect(transitionBlock).toBeGreaterThan(ariaLiveBlock);
	});

	it("status text span has the transition applied via style prop (not className)", () => {
		const stylePattern = /style=\{\{\s*transition:\s*"opacity 200ms ease"\s*\}\}/;
		expect(composerSource).toMatch(stylePattern);
	});
});
