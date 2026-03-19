/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

// Read the raw source for structural assertions that verify the fix patterns.
const sourcePath = fileURLToPath(new URL("./App.tsx", import.meta.url));
const source = readFileSync(sourcePath, "utf8");

// ---------------------------------------------------------------------------
// D-57: WebSocket event handler memoized with ref indirection pattern
// ---------------------------------------------------------------------------
describe("D-57: WS event handler ref indirection", () => {
	test("handleWsEventImpl is defined with useCallback", () => {
		expect(source).toContain("const handleWsEventImpl = useCallback(");
	});

	test("handleWsEventRef is declared to hold the latest impl", () => {
		expect(source).toContain("const handleWsEventRef = useRef(handleWsEventImpl)");
	});

	test("handleWsEventRef is updated on every render", () => {
		expect(source).toContain("handleWsEventRef.current = handleWsEventImpl");
	});

	test("stable handleWsEvent delegates through the ref", () => {
		expect(source).toContain("void handleWsEventRef.current(event)");
	});

	test("stable handleWsEvent has empty dependency array", () => {
		// The stable wrapper should have [] deps so the WS effect is stable
		const stableCallbackMatch = source.match(
			/const handleWsEvent = useCallback\(\s*\(event: ServerWsEvent\) => \{\s*void handleWsEventRef\.current\(event\);\s*\},\s*\[\],\s*\)/,
		);
		expect(stableCallbackMatch).not.toBeNull();
	});

	test("handleWsStateImpl is defined with useCallback", () => {
		expect(source).toContain("const handleWsStateImpl = useCallback(");
	});

	test("handleWsStateRef is declared to hold the latest impl", () => {
		expect(source).toContain("const handleWsStateRef = useRef(handleWsStateImpl)");
	});

	test("handleWsStateRef is updated on every render", () => {
		expect(source).toContain("handleWsStateRef.current = handleWsStateImpl");
	});

	test("stable handleWsState delegates through the ref", () => {
		expect(source).toContain("handleWsStateRef.current(connectionState)");
	});

	test("stable handleWsState has empty dependency array", () => {
		const stableCallbackMatch = source.match(
			/const handleWsState = useCallback\(\s*\(connectionState: ConnectionState\) => \{\s*handleWsStateRef\.current\(connectionState\);\s*\},\s*\[\],\s*\)/,
		);
		expect(stableCallbackMatch).not.toBeNull();
	});

	test("WS useEffect still depends on handleWsEvent and handleWsState", () => {
		// The WS connection effect must list both handlers
		expect(source).toContain("[baseUrl, handleWsEvent, handleWsState, token]");
	});
});
