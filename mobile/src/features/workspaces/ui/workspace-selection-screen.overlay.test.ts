/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "workspace-selection-screen.tsx"), "utf8");

describe("[M-45] workspace health check uses an overlay instead of replacing the screen", () => {
	it("keeps the main screen render and mounts a loading overlay", () => {
		expect(source).not.toContain("return (\n\t\t\t<View style={styles.root} testID=\"screen-workspaces-loading\">");
		expect(source).toContain("style={styles.healthCheckOverlay}");
		expect(source).toContain('testID="screen-workspaces-loading"');
	});

	it("defines the healthCheckOverlay style as an absolute overlay", () => {
		expect(source).toContain('position: "absolute"');
		expect(source).toContain("backgroundColor: \"rgba(13,15,20,0.72)\"");
	});
});
