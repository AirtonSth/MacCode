/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "active-threads-banner.tsx"), "utf8");

describe("[M-37] active threads banner reserves space instead of overlapping content", () => {
	it("wraps the animated banner in a regular View container", () => {
		expect(source).toContain("<View style={styles.wrapper}>");
		expect(source).toContain("style={[styles.bannerLayer, { opacity: fadeAnim }]}");
	});

	it("uses a fixed minHeight on the wrapper to reserve layout space", () => {
		expect(source).toContain("minHeight: 35");
		expect(source).toContain('position: "relative"');
	});
});
