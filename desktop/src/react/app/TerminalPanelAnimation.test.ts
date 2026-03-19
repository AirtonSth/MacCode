/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const appSource = readFileSync(resolve(__dirname, "App.tsx"), "utf-8");

describe("Terminal panel resize animation", () => {
	it("wraps the terminal panel conditional render in AnimatePresence", () => {
		expect(appSource).toContain("AnimatePresence");

		const animatePresenceImport = appSource.match(
			/import\s*\{[^}]*AnimatePresence[^}]*\}\s*from\s*["']framer-motion["']/,
		);
		expect(animatePresenceImport).not.toBeNull();

		const animatePresenceBlock = appSource.indexOf("<AnimatePresence");
		const terminalPanelBlock = appSource.indexOf("terminal-panel");
		const closingAnimatePresence = appSource.indexOf("</AnimatePresence>", animatePresenceBlock);

		expect(animatePresenceBlock).toBeGreaterThan(-1);
		expect(terminalPanelBlock).toBeGreaterThan(animatePresenceBlock);
		expect(closingAnimatePresence).toBeGreaterThan(terminalPanelBlock);
	});

	it("uses motion.div with overflow hidden for the animation wrapper", () => {
		const motionDivPattern = /<motion\.div[^>]*key="terminal-panel"[^>]*>/s;
		const match = appSource.match(motionDivPattern);
		expect(match).not.toBeNull();

		const motionDivStr = match![0];
		expect(motionDivStr).toContain("overflow-hidden");
	});

	it("animates height from 0 to auto and back to 0 on exit", () => {
		const motionDivPattern = /<motion\.div[^>]*key="terminal-panel"[^>]*>/s;
		const match = appSource.match(motionDivPattern);
		expect(match).not.toBeNull();

		const motionDivStr = match![0];
		expect(motionDivStr).toContain('initial={{ height: 0 }}');
		expect(motionDivStr).toContain('animate={{ height: "auto" }}');
		expect(motionDivStr).toContain("exit={{ height: 0 }}");
	});

	it("has the correct transition configuration with cubic bezier easing", () => {
		const transitionBlock = appSource.match(
			/transition=\{[\s\S]*?shouldReduceMotion[\s\S]*?\{ duration: 0\.3, ease: \[0\.4, 0, 0\.2, 1\] \}[\s\S]*?\}/,
		);
		expect(transitionBlock).not.toBeNull();
	});

	it("respects reduced motion preference with zero duration", () => {
		const reducedMotionFallback = appSource.match(
			/shouldReduceMotion\s*\?\s*\{\s*duration:\s*0\s*\}/,
		);
		expect(reducedMotionFallback).not.toBeNull();
	});

	it("sets AnimatePresence initial prop to false to skip mount animation", () => {
		expect(appSource).toContain("<AnimatePresence initial={false}>");
	});
});
