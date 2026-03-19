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

describe("[D-43] Provider and model selects show focus-visible affordance", () => {
	it("shared select class adds a focus-visible ring", () => {
		expect(composerSource).toContain("focus-visible:ring-2");
		expect(composerSource).toContain("focus-visible:ring-sky-400/60");
		expect(composerSource).toContain("focus-visible:ring-offset-[#181a1f]");
	});
});

describe("[D-56] Model dropdown avoids a premature empty state while loading", () => {
	it("supports a dedicated modelsLoading prop", () => {
		expect(composerSource).toContain("modelsLoading?: boolean");
		expect(composerSource).toContain("modelsLoading = false");
	});

	it("shows Loading models instead of No models during model fetches", () => {
		expect(composerSource).toContain('<option value="">Loading models...</option>');
	});
});

describe("[D-64] Provider stays fixed once a thread already has messages", () => {
	it("accepts a dedicated providerLocked prop", () => {
		expect(composerSource).toContain("providerLocked?: boolean");
		expect(composerSource).toContain("providerLocked = false");
	});

	it("disables only the provider select when providerLocked is true", () => {
		expect(composerSource).toContain("disabled={isInputLocked || providerLocked}");
	});
});

describe("[D-63] textarea respects composition and native editing shortcuts", () => {
	it("guards Enter-send while the user is composing accented characters", () => {
		expect(composerSource).toContain("event.nativeEvent.isComposing");
		expect(composerSource).toContain('event.key === "Dead"');
		expect(composerSource).toContain('event.key === "Process"');
	});

	it("adds explicit fallback handling for select-all and paste", () => {
		expect(composerSource).toContain("textareaRef.current?.select()");
		expect(composerSource).toContain("navigator.clipboard.readText()");
		expect(composerSource).toContain("replaceComposerSelection(clipboardText)");
	});
});
