import { useEffect, useRef, useState } from "react";

import {
	RemoteCodeApi,
	type CommitProjectRequestDTO,
	type GitBranchDTO,
	type GitStatusDTO,
} from "../../../shared/api/remotecode-http";

export interface ProjectGitState {
	status: GitStatusDTO | null;
	branches: GitBranchDTO[];
	loading: boolean;
	error: string | null;
}

export interface ProjectGitCommitInput {
	message: string;
	includeUnstaged?: boolean;
	push?: boolean;
}

export interface ProjectGitDependencies {
	projectId: string | null;
	api: ReturnType<typeof RemoteCodeApi.createClient>;
	onError?: (message: string) => void;
}

export interface ProjectGitController {
	getState: () => ProjectGitState;
	subscribe: (listener: () => void) => () => void;
	refresh: (options?: ProjectGitRefreshOptions) => Promise<void>;
	checkoutBranch: (branch: string) => Promise<void>;
	createBranch: (name: string) => Promise<void>;
	commit: (input: ProjectGitCommitInput) => Promise<void>;
}

interface ProjectGitRefreshOptions {
	silent?: boolean;
}

const createEmptyProjectGitState = (): ProjectGitState => ({
	status: null,
	branches: [],
	loading: false,
	error: null,
});

export const PROJECT_GIT_POLL_INTERVALS_MS = Object.freeze({
	active: 3_000,
	bootstrap: 5_000,
	error: 15_000,
	idle: 12_000,
	inactive: 30_000,
	nonRepository: 60_000,
});

export interface ProjectGitPollingRuntimeState {
	visibilityState: DocumentVisibilityState;
	hasWindowFocus: boolean;
}

interface ProjectGitPollingIntervalInput {
	state: ProjectGitState;
	runtime: ProjectGitPollingRuntimeState;
}

const hasGitStatusActivity = (status: GitStatusDTO): boolean => {
	return (
		status.changedFiles > 0 ||
		status.conflictedFiles > 0 ||
		status.ahead > 0 ||
		status.behind > 0 ||
		status.stagedFiles > 0 ||
		status.unstagedFiles > 0 ||
		status.untrackedFiles > 0
	);
};

export const resolveProjectGitPollIntervalMs = ({
	runtime,
	state,
}: ProjectGitPollingIntervalInput): number | null => {
	if (runtime.visibilityState === "hidden") {
		return null;
	}

	if (!runtime.hasWindowFocus) {
		return PROJECT_GIT_POLL_INTERVALS_MS.inactive;
	}

	if (state.error !== null) {
		return PROJECT_GIT_POLL_INTERVALS_MS.error;
	}

	if (state.status === null) {
		return PROJECT_GIT_POLL_INTERVALS_MS.bootstrap;
	}

	if (!state.status.isRepo) {
		return PROJECT_GIT_POLL_INTERVALS_MS.nonRepository;
	}

	return hasGitStatusActivity(state.status)
		? PROJECT_GIT_POLL_INTERVALS_MS.active
		: PROJECT_GIT_POLL_INTERVALS_MS.idle;
};

export interface ProjectGitPollingDocumentRuntime {
	readonly visibilityState: DocumentVisibilityState;
	hasFocus?: () => boolean;
	addEventListener: (type: "visibilitychange", listener: () => void) => void;
	removeEventListener: (type: "visibilitychange", listener: () => void) => void;
}

export interface ProjectGitPollingWindowRuntime {
	hasFocus?: () => boolean;
	addEventListener: (type: "focus" | "blur", listener: () => void) => void;
	removeEventListener: (type: "focus" | "blur", listener: () => void) => void;
}

type ProjectGitPollTimeoutHandle = ReturnType<typeof globalThis.setTimeout>;

interface StartProjectGitPollingOptions {
	projectId: string;
	getActiveProjectId: () => string | null;
	getState: () => ProjectGitState;
	refresh: () => Promise<void>;
	runtimeDocument?: ProjectGitPollingDocumentRuntime;
	runtimeWindow?: ProjectGitPollingWindowRuntime;
	scheduleTimeout?: (callback: () => void, timeoutMs: number) => ProjectGitPollTimeoutHandle;
	clearScheduledTimeout?: (timeoutHandle: ProjectGitPollTimeoutHandle) => void;
}

const getProjectGitPollingRuntimeState = (
	runtimeWindow?: ProjectGitPollingWindowRuntime,
	runtimeDocument?: ProjectGitPollingDocumentRuntime,
): ProjectGitPollingRuntimeState => {
	let hasWindowFocus = true;

	try {
		if (typeof runtimeDocument?.hasFocus === "function") {
			hasWindowFocus = runtimeDocument.hasFocus();
		} else if (typeof runtimeWindow?.hasFocus === "function") {
			hasWindowFocus = runtimeWindow.hasFocus();
		}
	} catch {
		hasWindowFocus = true;
	}

	return {
		hasWindowFocus,
		visibilityState: runtimeDocument?.visibilityState ?? "visible",
	};
};

export const startProjectGitPolling = (options: StartProjectGitPollingOptions): (() => void) => {
	const runtimeWindow = options.runtimeWindow ?? globalThis.window;
	const runtimeDocument = options.runtimeDocument ?? globalThis.document;
	const scheduleTimeout =
		options.scheduleTimeout ?? ((callback, timeoutMs) => globalThis.setTimeout(callback, timeoutMs));
	const clearScheduledTimeout =
		options.clearScheduledTimeout ??
		((timeoutHandle) => {
			globalThis.clearTimeout(timeoutHandle);
		});

	let disposed = false;
	let timeoutHandle: ProjectGitPollTimeoutHandle | null = null;

	const clearScheduledRefresh = () => {
		if (timeoutHandle === null) {
			return;
		}

		clearScheduledTimeout(timeoutHandle);
		timeoutHandle = null;
	};

	const isActiveProject = (): boolean => {
		return options.projectId === normalizeProjectId(options.getActiveProjectId());
	};

	const scheduleNextRefresh = () => {
		clearScheduledRefresh();
		if (disposed || !isActiveProject()) {
			return;
		}

		const intervalMs = resolveProjectGitPollIntervalMs({
			runtime: getProjectGitPollingRuntimeState(runtimeWindow, runtimeDocument),
			state: options.getState(),
		});
		if (intervalMs === null) {
			return;
		}

		timeoutHandle = scheduleTimeout(() => {
			timeoutHandle = null;
			void runRefreshCycle();
		}, intervalMs);
	};

	const runRefreshCycle = async (): Promise<void> => {
		if (disposed || !isActiveProject()) {
			return;
		}

		const runtime = getProjectGitPollingRuntimeState(runtimeWindow, runtimeDocument);
		if (runtime.visibilityState === "hidden") {
			scheduleNextRefresh();
			return;
		}

		try {
			await options.refresh();
		} finally {
			scheduleNextRefresh();
		}
	};

	const triggerImmediateRefresh = () => {
		if (disposed || !isActiveProject()) {
			return;
		}

		clearScheduledRefresh();
		void runRefreshCycle();
	};

	const handleVisibilityChange = () => {
		if (runtimeDocument?.visibilityState === "hidden") {
			clearScheduledRefresh();
			return;
		}

		triggerImmediateRefresh();
	};

	const handleFocus = () => {
		triggerImmediateRefresh();
	};

	const handleBlur = () => {
		scheduleNextRefresh();
	};

	runtimeDocument?.addEventListener("visibilitychange", handleVisibilityChange);
	runtimeWindow?.addEventListener("focus", handleFocus);
	runtimeWindow?.addEventListener("blur", handleBlur);

	scheduleNextRefresh();

	return () => {
		disposed = true;
		clearScheduledRefresh();
		runtimeDocument?.removeEventListener("visibilitychange", handleVisibilityChange);
		runtimeWindow?.removeEventListener("focus", handleFocus);
		runtimeWindow?.removeEventListener("blur", handleBlur);
	};
};

const normalizeProjectId = (projectId: string | null): string | null => {
	const trimmed = projectId?.trim() ?? "";
	return trimmed.length > 0 ? trimmed : null;
};

const normalizeBranchOrName = (value: string): string => value.trim();

const toErrorMessage = (error: unknown, fallback: string): string =>
	error instanceof Error && error.message.length > 0 ? error.message : fallback;

export const createProjectGitController = (
	getDependencies: () => ProjectGitDependencies,
	initialState: ProjectGitState = createEmptyProjectGitState(),
): ProjectGitController => {
	let state = initialState;
	const listeners = new Set<() => void>();
	const loadingByProject = new Map<string, Promise<void>>();
	let selectedProjectId: string | null = null;

	const notify = () => {
		for (const listener of listeners) {
			listener();
		}
	};

	const updateState = (updater: (current: ProjectGitState) => ProjectGitState) => {
		state = updater(state);
		notify();
	};

	const setEmptyState = () => {
		updateState(() => createEmptyProjectGitState());
	};

	const refreshProject = async (
		projectId: string,
		options: ProjectGitRefreshOptions = {},
	): Promise<void> => {
		const pending = loadingByProject.get(projectId);
		if (pending) {
			return pending;
		}

		const task = (async () => {
			const dependencies = getDependencies();
			if (projectId !== normalizeProjectId(dependencies.projectId)) {
				return;
			}

			updateState((current) =>
				options.silent && current.status !== null
					? {
							...current,
							error: null,
						}
					: {
							...current,
							error: null,
							loading: true,
						},
			);

			try {
				const [status, branches] = await Promise.all([
					dependencies.api.getProjectGitStatus(projectId),
					dependencies.api.getProjectGitBranches(projectId),
				]);

				updateState((current) => {
					if (projectId !== normalizeProjectId(getDependencies().projectId)) {
						return current;
					}

					return {
						error: null,
						loading: false,
						status,
						branches: branches.branches,
					};
				});
			} catch (error) {
				const message = toErrorMessage(error, "Unable to load project git state");
				updateState((current) => {
					if (projectId !== normalizeProjectId(getDependencies().projectId)) {
						return current;
					}

					return {
						...current,
						error: message,
						loading: false,
					};
				});
				dependencies.onError?.(message);
			}
		})();

		loadingByProject.set(projectId, task);
		await task.finally(() => {
			loadingByProject.delete(projectId);
		});
	};

	const runAction = async (action: (projectId: string) => Promise<unknown>): Promise<void> => {
		const dependencies = getDependencies();
		const projectId = normalizeProjectId(dependencies.projectId);

		if (!projectId) {
			const message = "No project selected for git action.";
			updateState((current) => ({ ...current, error: message, loading: false }));
			dependencies.onError?.(message);
			return;
		}

		if (projectId !== selectedProjectId) {
			selectedProjectId = projectId;
			setEmptyState();
		} else {
			updateState((current) => ({ ...current, error: null, loading: true }));
		}

		try {
			await action(projectId);
			if (projectId !== normalizeProjectId(getDependencies().projectId)) {
				return;
			}

			await refreshProject(projectId);
		} catch (error) {
			if (projectId !== normalizeProjectId(getDependencies().projectId)) {
				return;
			}

			const message = toErrorMessage(error, "Unable to update project git state");
			updateState((current) => ({
				...current,
				error: message,
				loading: false,
			}));
			dependencies.onError?.(message);
		}
	};

	return {
		getState: () => state,
		subscribe: (listener: () => void) => {
			listeners.add(listener);
			return () => {
				listeners.delete(listener);
			};
		},
		refresh: async (options = {}) => {
			const dependencies = getDependencies();
			const projectId = normalizeProjectId(dependencies.projectId);

			if (projectId === null) {
				selectedProjectId = null;
				setEmptyState();
				return;
			}

			if (projectId !== selectedProjectId) {
				selectedProjectId = projectId;
				setEmptyState();
			}

			await refreshProject(projectId, options);
		},
		checkoutBranch: async (branch: string) => {
			const normalizedBranch = normalizeBranchOrName(branch);
			await runAction(async (projectId) => {
				if (!normalizedBranch) {
					throw new Error("Branch name is required.");
				}

				await getDependencies().api.checkoutProjectGitBranch(projectId, normalizedBranch);
			});
		},
		createBranch: async (name: string) => {
			const normalizedName = normalizeBranchOrName(name);
			await runAction(async (projectId) => {
				if (!normalizedName) {
					throw new Error("Branch name is required.");
				}

				await getDependencies().api.createProjectGitBranch(projectId, normalizedName);
			});
		},
		commit: async (input: ProjectGitCommitInput) => {
			const message = normalizeBranchOrName(input.message);
			await runAction(async (projectId) => {
				if (!message) {
					throw new Error("Commit message is required.");
				}

				const commitInput: CommitProjectRequestDTO = {
					message,
					includeUnstaged: input.includeUnstaged ?? false,
					push: input.push ?? false,
				};

				await getDependencies().api.commitProject(projectId, commitInput);
			});
		},
	};
};

export interface UseProjectGitResult {
	state: ProjectGitState;
	refresh: () => Promise<void>;
	checkoutBranch: (branch: string) => Promise<void>;
	createBranch: (name: string) => Promise<void>;
	commit: (input: ProjectGitCommitInput) => Promise<void>;
}

export const useProjectGit = (dependencies: ProjectGitDependencies): UseProjectGitResult => {
	const dependenciesRef = useRef(dependencies);
	dependenciesRef.current = dependencies;

	const controllerRef = useRef<ProjectGitController | null>(null);
	const [, forceRender] = useState(0);

	if (!controllerRef.current) {
		controllerRef.current = createProjectGitController(() => dependenciesRef.current);
		controllerRef.current.subscribe(() => {
			forceRender((value) => value + 1);
		});
	}

	useEffect(() => {
		void controllerRef.current?.refresh();
	}, [dependencies.projectId]);

	useEffect(() => {
		const projectId = normalizeProjectId(dependencies.projectId);
		if (projectId === null) {
			return;
		}

		return startProjectGitPolling({
			projectId,
			getActiveProjectId: () => dependenciesRef.current.projectId,
			getState: () => controllerRef.current?.getState() ?? createEmptyProjectGitState(),
			refresh: async () => {
				await (controllerRef.current?.refresh({ silent: true }) ?? Promise.resolve());
			},
		});
	}, [dependencies.projectId]);

	return {
		state: controllerRef.current.getState(),
		refresh: controllerRef.current.refresh,
		checkoutBranch: controllerRef.current.checkoutBranch,
		createBranch: controllerRef.current.createBranch,
		commit: controllerRef.current.commit,
	};
};
