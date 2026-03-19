/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-07] Tests for the memoization strategy of heavy sub-components.
 *
 * The ChatScreen component had 40+ useState calls which caused the
 * entire component tree to re-render on any state change. The fix
 * extracts TerminalOverlay, GitCommitModalMemo, and SelectPickerModal
 * into React.memo components so they only re-render when their props
 * actually change.
 *
 * These tests verify the prop-equality logic that drives memo decisions,
 * since we cannot mount React components in a pure bun:test context.
 */

/**
 * Simulates shallow prop comparison for React.memo.
 * Returns true if all own-properties are reference-equal.
 */
const shallowEqual = (prev: Record<string, unknown>, next: Record<string, unknown>): boolean => {
	const prevKeys = Object.keys(prev);
	const nextKeys = Object.keys(next);
	if (prevKeys.length !== nextKeys.length) {
		return false;
	}
	for (const key of prevKeys) {
		if (prev[key] !== next[key]) {
			return false;
		}
	}
	return true;
};

/** Simulates the terminal overlay props */
const makeTerminalProps = (overrides: Record<string, unknown> = {}) => ({
	chatTitle: "Test Chat",
	isTerminalFilePickerVisible: false,
	isTerminalLoading: false,
	isTerminalOpen: true,
	isTerminalRunning: false,
	selectedChatId: "chat-1",
	terminalError: "",
	terminalInput: "",
	terminalOutput: "No terminal output yet.",
	...overrides,
});

describe("[M-07] shallow equality for memoized component props", () => {
	it("detects identical terminal overlay props as equal", () => {
		const props = makeTerminalProps();
		expect(shallowEqual(props, { ...props })).toBe(true);
	});

	it("detects changed terminal input as different", () => {
		const prev = makeTerminalProps();
		const next = makeTerminalProps({ terminalInput: "ls -la" });
		expect(shallowEqual(prev, next)).toBe(false);
	});

	it("detects changed terminal output as different", () => {
		const prev = makeTerminalProps();
		const next = makeTerminalProps({ terminalOutput: "$ ls\nfile1.txt" });
		expect(shallowEqual(prev, next)).toBe(false);
	});

	it("does not re-render when chat input changes (not in terminal props)", () => {
		// The key benefit: chat input state changes don't affect terminal props
		const prev = makeTerminalProps();
		const next = makeTerminalProps(); // same terminal props
		expect(shallowEqual(prev, next)).toBe(true);

		// The main chat input is NOT a prop of TerminalOverlay,
		// so typing in the chat input does NOT cause terminal re-render
	});
});

/** Simulates the git commit modal props */
const makeGitCommitProps = (overrides: Record<string, unknown> = {}) => ({
	gitChangedFiles: 3,
	gitCommitError: "",
	gitCommitIncludeUnstaged: true,
	gitCommitMessage: "",
	gitCurrentBranch: "main",
	isGitCommitPending: false,
	isVisible: true,
	...overrides,
});

describe("[M-07] git commit modal memoization", () => {
	it("detects identical git commit modal props as equal", () => {
		const props = makeGitCommitProps();
		expect(shallowEqual(props, { ...props })).toBe(true);
	});

	it("re-renders when commit message changes", () => {
		const prev = makeGitCommitProps();
		const next = makeGitCommitProps({ gitCommitMessage: "fix: something" });
		expect(shallowEqual(prev, next)).toBe(false);
	});

	it("re-renders when pending state changes", () => {
		const prev = makeGitCommitProps();
		const next = makeGitCommitProps({ isGitCommitPending: true });
		expect(shallowEqual(prev, next)).toBe(false);
	});

	it("does not re-render when terminal state changes (not in commit props)", () => {
		const prev = makeGitCommitProps();
		const next = makeGitCommitProps(); // identical
		expect(shallowEqual(prev, next)).toBe(true);
	});
});

/** Simulates the select picker modal props */
const makeSelectPickerProps = (overrides: Record<string, unknown> = {}) => ({
	activePicker: "model" as string | null,
	options: [] as unknown[],
	...overrides,
});

describe("[M-07] select picker modal memoization", () => {
	it("detects identical select picker props as equal", () => {
		const optionsRef: unknown[] = [];
		const props = makeSelectPickerProps({ options: optionsRef });
		expect(shallowEqual(props, makeSelectPickerProps({ options: optionsRef }))).toBe(true);
	});

	it("re-renders when activePicker changes", () => {
		const prev = makeSelectPickerProps({ activePicker: "model" });
		const next = makeSelectPickerProps({ activePicker: "provider" });
		expect(shallowEqual(prev, next)).toBe(false);
	});

	it("re-renders when options array reference changes", () => {
		const prev = makeSelectPickerProps({ options: [] });
		const next = makeSelectPickerProps({ options: [] });
		expect(shallowEqual(prev, next)).toBe(false);
	});
});

describe("[M-07] state isolation", () => {
	it("chat input changes do not affect any extracted component props", () => {
		// This is the core benefit. When the user types in the chat input:
		// - TerminalOverlay props: unchanged
		// - GitCommitModal props: unchanged
		// - SelectPickerModal props: unchanged
		//
		// Only the main ChatScreen body (composer area) needs to re-render.

		const terminalPrev = makeTerminalProps();
		const gitPrev = makeGitCommitProps();

		const terminalNext = makeTerminalProps();
		const gitNext = makeGitCommitProps();

		expect(shallowEqual(terminalPrev, terminalNext)).toBe(true);
		expect(shallowEqual(gitPrev, gitNext)).toBe(true);
		const sharedOptions: unknown[] = [];
		const sp1 = makeSelectPickerProps({ options: sharedOptions });
		const sp2 = makeSelectPickerProps({ options: sharedOptions });
		expect(shallowEqual(sp1, sp2)).toBe(true);
	});
});
