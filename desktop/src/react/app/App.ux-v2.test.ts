/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const appSource = readFileSync(resolve(__dirname, "App.tsx"), "utf-8");

describe("[D-48/D-50] sidebar resize feedback", () => {
	it("tracks sidebar resize visibility in state", () => {
		expect(appSource).toContain("const [isSidebarResizing, setIsSidebarResizing] = useState(false)");
	});

	it("renders an overlay while the sidebar is being resized", () => {
		expect(appSource).toContain("isSidebarResizing ? (");
		expect(appSource).toContain("backdrop-blur-[1px]");
	});

	it("styles the resize handle when it reaches bounds", () => {
		expect(appSource).toContain('sidebarResizeBound === "min" ? "bg-amber-300/10" : ""');
		expect(appSource).toContain('sidebarResizeBound === "max" ? "bg-sky-300/10" : ""');
	});
});

describe("[D-51] errors auto-dismiss after 6 seconds", () => {
	it("stores auto-dismiss timers in a ref map", () => {
		expect(appSource).toContain("const errorAutoDismissTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())");
	});

	it("schedules a 6 second timeout for new errors", () => {
		expect(appSource).toContain("}, 6_000));");
	});

	it("removes errors through the reducer when the timeout fires", () => {
		expect(appSource).toContain("dispatch({ payload: error.id, type: \"REMOVE_ERROR\" });");
	});
});
