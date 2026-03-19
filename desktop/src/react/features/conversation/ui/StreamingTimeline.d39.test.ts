/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

import { AUTO_COLLAPSE_DELAY_MS } from "./StreamingTimeline";

// Read the raw source for structural assertions that verify the fix patterns.
const sourcePath = fileURLToPath(new URL("./StreamingTimeline.tsx", import.meta.url));
const source = readFileSync(sourcePath, "utf8");

// ---------------------------------------------------------------------------
// D-39: Auto-collapse timer cleanup on unmount and item change
// ---------------------------------------------------------------------------
describe("D-39: auto-collapse timer cleanup", () => {
	test("AUTO_COLLAPSE_DELAY_MS is exported and equals 600", () => {
		expect(AUTO_COLLAPSE_DELAY_MS).toBe(600);
	});

	test("autoCollapseTimerRef is declared to store the timer ID", () => {
		expect(source).toContain("const autoCollapseTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)");
	});

	test("auto-collapse timer is stored in autoCollapseTimerRef", () => {
		expect(source).toContain("autoCollapseTimerRef.current = setTimeout(");
	});

	test("timer callback nullifies the ref after firing", () => {
		// When the timer fires, it should clear the ref to avoid double-clear
		expect(source).toContain("autoCollapseTimerRef.current = null;\n\t\t\tonSetItemExpanded(item.id, false, false);");
	});

	test("useEffect cleanup clears the auto-collapse timer", () => {
		// The effect that sets the timer should also clear it on cleanup
		expect(source).toContain("clearTimeout(autoCollapseTimerRef.current);\n\t\t\t\tautoCollapseTimerRef.current = null;");
	});

	test("separate useEffect clears auto-collapse timer when item.id changes", () => {
		// There should be a useEffect with [item.id] dep that clears the timer
		const itemIdCleanupMatch = source.match(
			/useEffect\(\(\) => \{\s*return \(\) => \{\s*if \(autoCollapseTimerRef\.current !== null\) \{\s*clearTimeout\(autoCollapseTimerRef\.current\);\s*autoCollapseTimerRef\.current = null;\s*\}\s*\};\s*\}, \[item\.id\]\)/,
		);
		expect(itemIdCleanupMatch).not.toBeNull();
	});

	test("auto-collapse timer is cleared before starting a new one", () => {
		// Before setting a new timer, the old one should be cleared
		const clearBeforeSetMatch = source.match(
			/if \(autoCollapseTimerRef\.current !== null\) \{\s*clearTimeout\(autoCollapseTimerRef\.current\);\s*\}\s*\n\s*autoCollapseTimerRef\.current = setTimeout/,
		);
		expect(clearBeforeSetMatch).not.toBeNull();
	});
});
