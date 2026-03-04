import { expect, test } from "bun:test";

import type { GitStatusDTO } from "../../../shared/api/remotecode-http";
import {
	PROJECT_GIT_POLL_INTERVALS_MS,
	resolveProjectGitPollIntervalMs,
	startProjectGitPolling,
	type ProjectGitPollingDocumentRuntime,
	type ProjectGitPollingWindowRuntime,
	type ProjectGitState,
} from "./useProjectGit";

const createStatus = (overrides: Partial<GitStatusDTO> = {}): GitStatusDTO => ({
	isRepo: true,
	currentBranch: "main",
	ahead: 0,
	behind: 0,
	changedFiles: 0,
	stagedFiles: 0,
	unstagedFiles: 0,
	untrackedFiles: 0,
	conflictedFiles: 0,
	isDetachedHead: false,
	added: 0,
	removed: 0,
	...overrides,
});

const createState = (overrides: Partial<ProjectGitState> = {}): ProjectGitState => ({
	status: null,
	branches: [],
	loading: false,
	error: null,
	...overrides,
});

const flushAsync = async () => {
	await Promise.resolve();
	await Promise.resolve();
};

const createMockTimer = () => {
	type TimerEntry = {
		callback: () => void;
		timeoutMs: number;
	};

	const timers = new Map<number, TimerEntry>();
	let nextId = 1;

	const scheduleTimeout = (callback: () => void, timeoutMs: number): ReturnType<typeof globalThis.setTimeout> => {
		const timerId = nextId;
		nextId += 1;
		timers.set(timerId, { callback, timeoutMs });
		return timerId as unknown as ReturnType<typeof globalThis.setTimeout>;
	};

	const clearScheduledTimeout = (timerId: ReturnType<typeof globalThis.setTimeout>) => {
		timers.delete(timerId as unknown as number);
	};

	const getSingleDelay = (): number => {
		const activeTimers = [...timers.values()];
		expect(activeTimers).toHaveLength(1);
		return activeTimers[0]?.timeoutMs ?? -1;
	};

	return {
		scheduleTimeout,
		clearScheduledTimeout,
		getSingleDelay,
		getScheduledCount: () => timers.size,
	};
};

const createMockRuntime = () => {
	type DocumentEventType = "visibilitychange";
	type WindowEventType = "focus" | "blur";

	let visibilityState: DocumentVisibilityState = "visible";
	let focused = true;
	const documentListeners: Record<DocumentEventType, Set<() => void>> = {
		visibilitychange: new Set(),
	};
	const windowListeners: Record<WindowEventType, Set<() => void>> = {
		blur: new Set(),
		focus: new Set(),
	};

	const runtimeDocument: ProjectGitPollingDocumentRuntime = {
		get visibilityState() {
			return visibilityState;
		},
		hasFocus: () => focused,
		addEventListener: (type, listener) => {
			documentListeners[type].add(listener);
		},
		removeEventListener: (type, listener) => {
			documentListeners[type].delete(listener);
		},
	};

	const runtimeWindow: ProjectGitPollingWindowRuntime = {
		hasFocus: () => focused,
		addEventListener: (type, listener) => {
			windowListeners[type].add(listener);
		},
		removeEventListener: (type, listener) => {
			windowListeners[type].delete(listener);
		},
	};

	return {
		runtimeDocument,
		runtimeWindow,
		setFocused: (value: boolean) => {
			focused = value;
		},
		setVisibilityState: (state: DocumentVisibilityState) => {
			visibilityState = state;
		},
		emitVisibilityChange: () => {
			for (const listener of documentListeners.visibilitychange) {
				listener();
			}
		},
		emitFocus: () => {
			for (const listener of windowListeners.focus) {
				listener();
			}
		},
		emitBlur: () => {
			for (const listener of windowListeners.blur) {
				listener();
			}
		},
	};
};

test("resolveProjectGitPollIntervalMs adapts to visibility, focus, and git activity", () => {
	const dirtyState = createState({
		status: createStatus({
			changedFiles: 3,
		}),
	});
	const cleanState = createState({
		status: createStatus(),
	});

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "hidden",
				hasWindowFocus: true,
			},
			state: cleanState,
		}),
	).toBeNull();

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: true,
			},
			state: dirtyState,
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.active);

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: true,
			},
			state: cleanState,
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.idle);

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: false,
			},
			state: dirtyState,
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.inactive);
});

test("resolveProjectGitPollIntervalMs prefers error, bootstrap, and non-repo cadences", () => {
	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: true,
			},
			state: createState({
				error: "Unable to load project git state",
			}),
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.error);

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: true,
			},
			state: createState(),
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.bootstrap);

	expect(
		resolveProjectGitPollIntervalMs({
			runtime: {
				visibilityState: "visible",
				hasWindowFocus: true,
			},
			state: createState({
				status: createStatus({
					isRepo: false,
				}),
			}),
		}),
	).toBe(PROJECT_GIT_POLL_INTERVALS_MS.nonRepository);
});

test("startProjectGitPolling pauses while hidden and refreshes immediately when visible again", async () => {
	const timer = createMockTimer();
	const runtime = createMockRuntime();
	const refreshCalls: number[] = [];
	const state = createState({
		status: createStatus(),
	});

	const cleanup = startProjectGitPolling({
		projectId: "project-1",
		getActiveProjectId: () => "project-1",
		getState: () => state,
		refresh: async () => {
			refreshCalls.push(Date.now());
		},
		runtimeDocument: runtime.runtimeDocument,
		runtimeWindow: runtime.runtimeWindow,
		scheduleTimeout: timer.scheduleTimeout,
		clearScheduledTimeout: timer.clearScheduledTimeout,
	});

	expect(timer.getSingleDelay()).toBe(PROJECT_GIT_POLL_INTERVALS_MS.idle);

	runtime.setVisibilityState("hidden");
	runtime.emitVisibilityChange();
	expect(timer.getScheduledCount()).toBe(0);
	expect(refreshCalls).toHaveLength(0);

	runtime.setVisibilityState("visible");
	runtime.emitVisibilityChange();
	await flushAsync();

	expect(refreshCalls).toHaveLength(1);
	expect(timer.getSingleDelay()).toBe(PROJECT_GIT_POLL_INTERVALS_MS.idle);

	cleanup();
});

test("startProjectGitPolling slows on blur and refreshes immediately on focus", async () => {
	const timer = createMockTimer();
	const runtime = createMockRuntime();
	const refreshCalls: number[] = [];
	const state = createState({
		status: createStatus({
			changedFiles: 2,
			stagedFiles: 1,
		}),
	});

	const cleanup = startProjectGitPolling({
		projectId: "project-1",
		getActiveProjectId: () => "project-1",
		getState: () => state,
		refresh: async () => {
			refreshCalls.push(Date.now());
		},
		runtimeDocument: runtime.runtimeDocument,
		runtimeWindow: runtime.runtimeWindow,
		scheduleTimeout: timer.scheduleTimeout,
		clearScheduledTimeout: timer.clearScheduledTimeout,
	});

	expect(timer.getSingleDelay()).toBe(PROJECT_GIT_POLL_INTERVALS_MS.active);

	runtime.setFocused(false);
	runtime.emitBlur();
	expect(timer.getSingleDelay()).toBe(PROJECT_GIT_POLL_INTERVALS_MS.inactive);

	runtime.setFocused(true);
	runtime.emitFocus();
	await flushAsync();

	expect(refreshCalls).toHaveLength(1);
	expect(timer.getSingleDelay()).toBe(PROJECT_GIT_POLL_INTERVALS_MS.active);

	cleanup();
});
