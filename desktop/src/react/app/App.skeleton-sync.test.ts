/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const appSource = readFileSync(resolve(__dirname, "App.tsx"), "utf-8");
const cssSource = readFileSync(resolve(__dirname, "../index.css"), "utf-8");

// ---------------------------------------------------------------------------
// D-42: Skeleton pulses are synchronized
// ---------------------------------------------------------------------------
describe("[D-42] Skeleton pulses synchronized", () => {
	it("sidebar skeleton divs use skeleton-pulse-sync class instead of animate-pulse", () => {
		const skeletonBlock = appSource.match(
			/projectsLoading[\s\S]*?space-y-3[\s\S]*?projects\.length/,
		);
		expect(skeletonBlock).not.toBeNull();

		const block = skeletonBlock![0];
		expect(block).toContain("skeleton-pulse-sync");
		expect(block).not.toContain("animate-pulse");
	});

	it("CSS defines the skeleton-pulse-sync class with shared animation timing", () => {
		expect(cssSource).toContain(".skeleton-pulse-sync");
	});

	it("skeleton-pulse-sync class uses animation-delay: 0ms for synchronization", () => {
		const syncBlock = cssSource.match(
			/\.skeleton-pulse-sync\s*\{[\s\S]*?\}/,
		);
		expect(syncBlock).not.toBeNull();
		expect(syncBlock![0]).toContain("animation-delay: 0ms");
	});

	it("skeleton-pulse-sync class uses a pulse animation", () => {
		const syncBlock = cssSource.match(
			/\.skeleton-pulse-sync\s*\{[\s\S]*?\}/,
		);
		expect(syncBlock).not.toBeNull();
		expect(syncBlock![0]).toContain("animation:");
		expect(syncBlock![0]).toContain("pulse");
	});

	it("all skeleton divs in the loading block use the sync class", () => {
		const skeletonBlock = appSource.match(
			/projectsLoading[\s\S]*?space-y-3([\s\S]*?)projects\.length/,
		);
		expect(skeletonBlock).not.toBeNull();

		const block = skeletonBlock![1];
		const syncMatches = block.match(/skeleton-pulse-sync/g);
		expect(syncMatches).not.toBeNull();
		expect(syncMatches!.length).toBe(7);
	});
});
