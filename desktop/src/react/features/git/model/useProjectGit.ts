import { useEffect, useRef, useState } from "react";

import type { CommitProjectRequestDTO, GitBranchDTO, GitStatusDTO } from "../../../shared/api/remotecode-http";
import { RemoteCodeApi } from "../../../shared/api/remotecode-http";

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

const GIT_STATUS_POLL_INTERVAL_MS = 2_000;

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
		if (normalizeProjectId(dependencies.projectId) === null) {
			return;
		}

		const intervalHandle = globalThis.setInterval(() => {
			void controllerRef.current?.refresh({ silent: true });
		}, GIT_STATUS_POLL_INTERVAL_MS);

		return () => {
			globalThis.clearInterval(intervalHandle);
		};
	}, [dependencies.projectId]);

	return {
		state: controllerRef.current.getState(),
		refresh: controllerRef.current.refresh,
		checkoutBranch: controllerRef.current.checkoutBranch,
		createBranch: controllerRef.current.createBranch,
		commit: controllerRef.current.commit,
	};
};
