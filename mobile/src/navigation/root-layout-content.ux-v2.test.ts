/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "root-layout-content.tsx"), "utf8");

describe("[M-43] splash animation is skipped when data is ready on mount", () => {
	it("captures the ready-on-mount state in a ref", () => {
		expect(source).toContain("const dataReadyOnMountRef = useRef(isConfigLoaded && isSessionLoaded);");
	});

	it("passes shouldSkipAnimation to AnimatedLaunchSplash", () => {
		expect(source).toContain("shouldSkipAnimation={dataReadyOnMountRef.current}");
	});
});
