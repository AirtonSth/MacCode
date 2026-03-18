/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import { resolveThreadLiveActivityCompactGlyph } from "./thread-live-activity.widget.presentation";

describe("thread live activity widget presentation", () => {
	test("uses the active thread count as the compact glyph when available", () => {
		expect(
			resolveThreadLiveActivityCompactGlyph({
				phase: "running",
				statusLine: "4 threads active",
			}),
		).toBe("4");
	});

	test("falls back to phase-specific compact glyphs when there is no count", () => {
		expect(
			resolveThreadLiveActivityCompactGlyph({
				phase: "completed",
				statusLine: "All threads completed",
			}),
		).toBe("C");
		expect(
			resolveThreadLiveActivityCompactGlyph({
				phase: "background",
				statusLine: "1 thread active",
			}),
		).toBe("B");
	});
});
