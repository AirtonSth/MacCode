/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const gitBranchSource = readFileSync(resolve(__dirname, "GitBranchControl.tsx"), "utf-8");

describe("[D-31] Git branch dropdown animation", () => {
	it("imports AnimatePresence and motion from framer-motion", () => {
		const framerImport = gitBranchSource.match(
			/import\s*\{[^}]*AnimatePresence[^}]*motion[^}]*\}\s*from\s*["']framer-motion["']/,
		);
		expect(framerImport).not.toBeNull();
	});

	it("wraps dropdown in AnimatePresence", () => {
		expect(gitBranchSource).toContain("<AnimatePresence>");
		expect(gitBranchSource).toContain("</AnimatePresence>");
	});

	it("uses motion.div with key for the dropdown panel", () => {
		const motionDivPattern = /<motion\.div[^>]*key="git-branch-dropdown"/s;
		expect(gitBranchSource).toMatch(motionDivPattern);
	});

	it("defines initial, animate, and exit props for opacity and translateY", () => {
		expect(gitBranchSource).toContain("initial={{ opacity: 0, y: 4 }}");
		expect(gitBranchSource).toContain("animate={{ opacity: 1, y: 0 }}");
		expect(gitBranchSource).toContain("exit={{ opacity: 0, y: 4 }}");
	});

	it("has a transition with duration", () => {
		const transitionProp = gitBranchSource.match(/transition=\{\{[^}]*duration:\s*0\.15[^}]*\}\}/);
		expect(transitionProp).not.toBeNull();
	});
});

describe("[D-32] Branch items do not flash disabled during checkout", () => {
	it("closes dropdown (setIsOpen false) before setting isSubmitting true in handleCheckout", () => {
		const handleCheckoutBlock = gitBranchSource.match(
			/const handleCheckout[\s\S]*?finally\s*\{[\s\S]*?\}/,
		);
		expect(handleCheckoutBlock).not.toBeNull();

		const source = handleCheckoutBlock![0];
		const closeIndex = source.indexOf("setIsOpen(false)");
		const submittingIndex = source.indexOf("setIsSubmitting(true)");

		expect(closeIndex).toBeGreaterThan(-1);
		expect(submittingIndex).toBeGreaterThan(-1);
		expect(closeIndex).toBeLessThan(submittingIndex);
	});

	it("branch item buttons have an opacity transition for the disabled state", () => {
		expect(gitBranchSource).toContain("transition-[color,background-color,opacity]");
		expect(gitBranchSource).toContain("duration-150");
	});
});

describe("[D-33] Non-git-repository message is a hover tooltip", () => {
	it("shows the message as a tooltip with role=tooltip", () => {
		expect(gitBranchSource).toContain('role="tooltip"');
	});

	it("the non-git message is hidden by default with opacity-0", () => {
		const tooltipBlock = gitBranchSource.match(/Not a git repository[\s\S]{0,50}/);
		expect(tooltipBlock).not.toBeNull();

		// Find the element containing the tooltip text
		const tooltipElement = gitBranchSource.match(/<p[^>]*role="tooltip"[^>]*>/s);
		expect(tooltipElement).not.toBeNull();
		expect(tooltipElement![0]).toContain("opacity-0");
	});

	it("the message becomes visible on group hover via group-hover:opacity-100", () => {
		const tooltipElement = gitBranchSource.match(/<p[^>]*role="tooltip"[^>]*>/s);
		expect(tooltipElement).not.toBeNull();
		expect(tooltipElement![0]).toContain("group-hover:opacity-100");
	});

	it("the container div has the 'group' class for hover propagation", () => {
		expect(gitBranchSource).toContain('className="group relative shrink-0"');
	});

	it("no longer shows the old persistent error paragraph", () => {
		expect(gitBranchSource).not.toContain("This project is not a git repository");
	});
});

describe("[D-36] GitBranchControl uses pointerdown instead of mousedown", () => {
	it("registers a pointerdown event listener on window", () => {
		expect(gitBranchSource).toContain('"pointerdown"');
	});

	it("does not use mousedown event listener", () => {
		expect(gitBranchSource).not.toContain('"mousedown"');
		expect(gitBranchSource).not.toContain("'mousedown'");
	});

	it("adds and removes pointerdown listener symmetrically", () => {
		expect(gitBranchSource).toContain('window.addEventListener("pointerdown"');
		expect(gitBranchSource).toContain('window.removeEventListener("pointerdown"');
	});

	it("types the handler parameter as PointerEvent instead of MouseEvent", () => {
		expect(gitBranchSource).toContain("(event: PointerEvent)");
		expect(gitBranchSource).not.toContain("(event: MouseEvent)");
	});
});
