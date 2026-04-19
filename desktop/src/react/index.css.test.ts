/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const cssSource = readFileSync(resolve(__dirname, "index.css"), "utf-8");
const htmlSource = readFileSync(resolve(__dirname, "index.html"), "utf-8");

describe("[D-13] Google Fonts display=swap and @font-face fallback", () => {
	it("includes display=swap in the Google Fonts preload link URL (loaded via <link> in index.html)", () => {
		const fontsLink = htmlSource.match(/href="https:\/\/fonts\.googleapis\.com\/css2[^"]+"/);
		expect(fontsLink).not.toBeNull();
		expect(fontsLink![0]).toContain("display=swap");
	});

	it("declares @font-face for Manrope with font-display: swap", () => {
		const manropeFontFace = cssSource.match(
			/@font-face\s*\{[^}]*font-family:\s*"Manrope"[^}]*font-display:\s*swap[^}]*\}/s,
		);
		expect(manropeFontFace).not.toBeNull();
	});

	it("declares @font-face for Plus Jakarta Sans with font-display: swap", () => {
		const jakartaFontFace = cssSource.match(
			/@font-face\s*\{[^}]*font-family:\s*"Plus Jakarta Sans"[^}]*font-display:\s*swap[^}]*\}/s,
		);
		expect(jakartaFontFace).not.toBeNull();
	});
});

describe("[D-24] prefers-reduced-motion is selective", () => {
	it("removes animation-duration in the reduced-motion media query", () => {
		const reducedMotionBlock = cssSource.match(
			/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([\s\S]*?)\n\}/,
		);
		expect(reducedMotionBlock).not.toBeNull();
		const blockContent = reducedMotionBlock![1];
		expect(blockContent).toContain("animation-duration: 0.001ms !important");
	});

	it("removes animation-iteration-count in the reduced-motion media query", () => {
		const reducedMotionBlock = cssSource.match(
			/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([\s\S]*?)\n\}/,
		);
		expect(reducedMotionBlock).not.toBeNull();
		const blockContent = reducedMotionBlock![1];
		expect(blockContent).toContain("animation-iteration-count: 1 !important");
	});

	it("does NOT kill transition-duration in the reduced-motion media query", () => {
		const reducedMotionBlock = cssSource.match(
			/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([\s\S]*?)\n\}/,
		);
		expect(reducedMotionBlock).not.toBeNull();
		const blockContent = reducedMotionBlock![1];
		expect(blockContent).not.toContain("transition-duration");
	});

	it("still disables scroll-behavior in the reduced-motion media query", () => {
		const reducedMotionBlock = cssSource.match(
			/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([\s\S]*?)\n\}/,
		);
		expect(reducedMotionBlock).not.toBeNull();
		const blockContent = reducedMotionBlock![1];
		expect(blockContent).toContain("scroll-behavior: auto !important");
	});
});
