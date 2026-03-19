/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

/**
 * [M-40] Tests for zIndex layering between terminal overlay and modals.
 *
 * Previously, the terminal overlay had no zIndex and modals (git commit,
 * select picker) could render behind it. The fix adds explicit zIndex
 * values:
 *   - terminalRoot: zIndex 100
 *   - gitCommitModalBackdrop: zIndex 200
 *   - selectModalBackdrop: zIndex 200
 *
 * This ensures modals always render above the terminal overlay.
 *
 * Because chat-screen-styles.ts imports react-native (which cannot be
 * loaded in bun:test), we parse the source file directly to verify the
 * zIndex values are present and correctly ordered.
 */

const stylesPath = resolve(__dirname, "chat-screen-styles.ts");
const stylesSource = readFileSync(stylesPath, "utf8");

/**
 * Extracts the numeric zIndex value from a named style block.
 * Looks for `styleName: {` followed by `zIndex: <number>` before the
 * closing `}`.
 */
function extractZIndex(source: string, styleName: string): number | null {
	const blockStart = source.indexOf(`${styleName}: {`);
	if (blockStart === -1) {
		return null;
	}

	const blockEnd = source.indexOf("\n\t},", blockStart);
	if (blockEnd === -1) {
		return null;
	}

	const block = source.slice(blockStart, blockEnd);
	const zIndexMatch = /zIndex\s*:\s*(?<zIndex>\d+)/.exec(block);
	if (!zIndexMatch?.groups?.zIndex) {
		return null;
	}
	return Number(zIndexMatch.groups.zIndex);
}

describe("[M-40] terminal overlay zIndex", () => {
	it("terminalRoot has zIndex 100", () => {
		const zIndex = extractZIndex(stylesSource, "terminalRoot");
		expect(zIndex).toBe(100);
	});
});

describe("[M-40] modal backdrops have higher zIndex than terminal", () => {
	it("gitCommitModalBackdrop has zIndex 200", () => {
		const zIndex = extractZIndex(stylesSource, "gitCommitModalBackdrop");
		expect(zIndex).toBe(200);
	});

	it("selectModalBackdrop has zIndex 200", () => {
		const zIndex = extractZIndex(stylesSource, "selectModalBackdrop");
		expect(zIndex).toBe(200);
	});
});

describe("[M-40] modal zIndex is greater than terminal zIndex", () => {
	it("git commit modal renders above terminal overlay", () => {
		const terminalZIndex = extractZIndex(stylesSource, "terminalRoot");
		const modalZIndex = extractZIndex(stylesSource, "gitCommitModalBackdrop");
		expect(terminalZIndex).not.toBeNull();
		expect(modalZIndex).not.toBeNull();
		expect(modalZIndex!).toBeGreaterThan(terminalZIndex!);
	});

	it("select picker modal renders above terminal overlay", () => {
		const terminalZIndex = extractZIndex(stylesSource, "terminalRoot");
		const modalZIndex = extractZIndex(stylesSource, "selectModalBackdrop");
		expect(terminalZIndex).not.toBeNull();
		expect(modalZIndex).not.toBeNull();
		expect(modalZIndex!).toBeGreaterThan(terminalZIndex!);
	});
});
