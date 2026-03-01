import { CheckSquare2, GitBranch, Loader2, X } from "lucide-react";
import { type FormEvent, useCallback, useEffect, useState } from "react";

import { Badge } from "../../../components/ui/badge";
import { Button } from "../../../components/ui/button";
import { cn } from "../../../lib/utils";
import type { CommitProjectRequestDTO, GitStatusDTO, ProjectDTO } from "../../../shared/api/remotecode-http";

interface GitClient {
	getProjectGitStatus: (projectId: string) => Promise<GitStatusDTO>;
	commitProject: (
		projectId: string,
		input: CommitProjectRequestDTO,
	) => Promise<{
		commit: {
			branch: string | null;
			commitHash: string | null;
			commitMessage: string;
			pushed: boolean;
			pushedWithUpstream: boolean;
		};
	}>;
}

interface GitQuickControlProps {
	client: GitClient;
	project: Pick<ProjectDTO, "id" | "name" | "path"> | null;
	disabled?: boolean;
	className?: string;
	onCommitted?: (commit: {
		branch: string | null;
		commitHash: string | null;
		commitMessage: string;
		pushed: boolean;
		pushedWithUpstream: boolean;
	}) => void;
}

const toRepoDescriptor = (project: Pick<ProjectDTO, "name" | "path"> | null): string => {
	if (!project) {
		return "No project selected";
	}

	const name = project.name.trim().length > 0 ? project.name : "Project";
	return `${name} · ${project.path}`;
};

const toCommitButtonLabel = (added: number, removed: number): string => `+${added} / -${removed}`;
const hasText = (value: string): boolean => value.trim().length > 0;

export const GitQuickControl = ({
	client,
	className,
	disabled = false,
	project,
	onCommitted,
}: GitQuickControlProps): JSX.Element => {
	const projectId = project?.id ?? null;

	const [isPanelOpen, setIsPanelOpen] = useState(false);
	const [status, setStatus] = useState<GitStatusDTO | null>(null);
	const [isLoadingStatus, setIsLoadingStatus] = useState(false);
	const [statusError, setStatusError] = useState<string | null>(null);
	const [commitMessage, setCommitMessage] = useState("");
	const [includeUnstaged, setIncludeUnstaged] = useState(false);
	const [isCommitting, setIsCommitting] = useState(false);
	const [actionError, setActionError] = useState<string | null>(null);
	const [actionFeedback, setActionFeedback] = useState<string | null>(null);

	const isRepo = status?.isRepo === true;
	const hasStatus = status !== null;
	const isBusy = isLoadingStatus || isCommitting;
	const canCommit = hasText(commitMessage) && isRepo && !isBusy && !disabled;
	const isControlBusy = isBusy || (hasStatus && !isRepo);
	const addedCount = isRepo ? status.added : 0;
	const removedCount = isRepo ? status.removed : 0;
	const changedCount = status ? status.changedFiles : 0;

	const clearCommitState = useCallback(() => {
		setCommitMessage("");
		setIncludeUnstaged(false);
	}, []);

	const resetTransientState = useCallback(() => {
		setStatus(null);
		setStatusError(null);
		setActionError(null);
		setActionFeedback(null);
		clearCommitState();
	}, [clearCommitState]);

	const fetchStatus = useCallback(async () => {
		if (!projectId) {
			resetTransientState();
			return;
		}

		setStatusError(null);
		setActionError(null);
		setActionFeedback(null);
		setIsLoadingStatus(true);

		try {
			const next = await client.getProjectGitStatus(projectId);
			setStatus(next);
			if (!next.isRepo) {
				clearCommitState();
			}
		} catch (error: unknown) {
			resetTransientState();
			setStatusError(error instanceof Error ? error.message : "Unable to load git status");
		} finally {
			setIsLoadingStatus(false);
		}
	}, [clearCommitState, client, projectId, resetTransientState]);

	const closePanel = useCallback(() => {
		setIsPanelOpen(false);
		setStatusError(null);
		setActionError(null);
		setActionFeedback(null);
		clearCommitState();
	}, [clearCommitState]);

	const runCommit = useCallback(
		async (push: boolean) => {
			if (!projectId || !canCommit) {
				return;
			}

			setActionError(null);
			setActionFeedback(null);
			setIsCommitting(true);

			try {
				const response = await client.commitProject(projectId, {
					message: commitMessage.trim(),
					includeUnstaged,
					push,
				});

				setActionFeedback(
					response.commit.pushed
						? `Committed and pushed: ${response.commit.commitMessage}`
						: `Committed: ${response.commit.commitMessage}`,
				);
				onCommitted?.(response.commit);
				clearCommitState();
				await fetchStatus();
			} catch (error: unknown) {
				setActionError(error instanceof Error ? error.message : "Unable to create commit");
			} finally {
				setIsCommitting(false);
			}
		},
		[
			canCommit,
			commitMessage,
			clearCommitState,
			client,
			fetchStatus,
			includeUnstaged,
			projectId,
			onCommitted,
		],
	);

	const handleCommit = useCallback(
		(event: FormEvent<HTMLFormElement>) => {
			event.preventDefault();
			if (!canCommit) {
				return;
			}
			void runCommit(false);
		},
		[canCommit, runCommit],
	);

	const handleCommitAndPush = useCallback(() => {
		if (!canCommit) {
			return;
		}
		void runCommit(true);
	}, [canCommit, runCommit]);

	const handleTogglePanel = useCallback(() => {
		if (!projectId || disabled || isLoadingStatus) {
			return;
		}
		setIsPanelOpen((current) => !current);
		setActionError(null);
		setActionFeedback(null);
	}, [disabled, isLoadingStatus, projectId]);

	useEffect(() => {
		if (!projectId || disabled) {
			setIsPanelOpen(false);
			resetTransientState();
			return;
		}

		void fetchStatus();
	}, [disabled, fetchStatus, projectId, resetTransientState]);

	return (
		<div className={cn("relative inline-flex", className)}>
			<Button
				aria-label="Toggle Git quick control"
				className="h-8 px-2"
				disabled={isControlBusy || !projectId || disabled}
				onClick={handleTogglePanel}
				type="button"
				variant="outline"
			>
				<GitBranch className="h-3.5 w-3.5" />
				<span className="font-mono text-[11px]">{toCommitButtonLabel(addedCount, removedCount)}</span>
				<Badge className="h-5 rounded-full px-1.5 text-[10px] uppercase tracking-[0.11em] text-slate-100">Git</Badge>
			</Button>

			{isPanelOpen ? (
				<div className="absolute right-0 z-40 mt-2 w-80 rounded-xl border border-white/10 bg-slate-950/90 p-3 shadow-2xl backdrop-blur-xl">
					<div className="mb-2 flex items-center justify-between gap-2">
						<div className="min-w-0">
							<h3 className="truncate text-sm font-semibold text-slate-100">Git quick commit</h3>
							<p className="truncate text-xs text-slate-400">{toRepoDescriptor(project)}</p>
						</div>
						<div className="flex items-center gap-1.5">
							{isLoadingStatus ? <Loader2 className="h-3.5 w-3.5 animate-spin text-slate-300" /> : null}
							<Button
								aria-label="Close Git quick commit panel"
								className="h-7 w-7"
								onClick={closePanel}
								variant="ghost"
								type="button"
							>
								<X className="h-3.5 w-3.5" />
							</Button>
						</div>
					</div>

					<div className="space-y-2 text-xs text-slate-200">
						{isLoadingStatus ? (
							<p className="rounded-md border border-white/10 px-2 py-1 text-slate-300">Loading git status…</p>
						) : statusError ? (
							<p className="rounded-md bg-rose-500/10 px-2 py-1 text-rose-100">{statusError}</p>
						) : isRepo ? (
							<>
								<div className="flex flex-wrap gap-2">
									<div className="rounded-md border border-white/10 px-2 py-1.5">
										<p className="text-[10px] uppercase text-slate-400">Branch</p>
										<p className="font-medium text-slate-100">
											{status?.currentBranch ?? (status?.isDetachedHead ? "Detached" : "Unknown")}
										</p>
									</div>
									<div className="rounded-md border border-white/10 px-2 py-1.5">
										<p className="text-[10px] uppercase text-slate-400">Ahead / behind</p>
										<p className="font-medium text-slate-100">
											{status?.ahead ?? 0}/{status?.behind ?? 0}
										</p>
									</div>
								</div>
								<div className="space-y-1 rounded-md border border-white/10 px-2 py-2">
									<p className="text-[10px] uppercase text-slate-400">Files</p>
									<ul className="grid grid-cols-2 gap-x-3 gap-y-1 text-[11px]">
										<li>Changed: {changedCount}</li>
										<li>Staged: {status?.stagedFiles ?? 0}</li>
										<li>Unstaged: {status?.unstagedFiles ?? 0}</li>
										<li>Untracked: {status?.untrackedFiles ?? 0}</li>
										<li>Added: {status?.added ?? 0}</li>
										<li>Removed: {status?.removed ?? 0}</li>
										<li>Conflicted: {status?.conflictedFiles ?? 0}</li>
									</ul>
								</div>

								<form className="space-y-2" onSubmit={handleCommit}>
									<label className="block text-[10px] uppercase tracking-[0.14em] text-slate-300" htmlFor="git-quick-commit-message">
										Commit message
									</label>
									<input
										aria-label="Commit message"
										className="h-10 w-full rounded-md border border-white/10 bg-slate-900/80 px-2 text-sm text-slate-100 outline-none placeholder:text-slate-500"
										disabled={isBusy || !isRepo}
										id="git-quick-commit-message"
										onChange={(event) => {
											setCommitMessage(event.target.value);
										}}
										placeholder="Enter commit message"
										value={commitMessage}
									/>

									<label className="flex items-center gap-2 text-[11px] text-slate-300">
										<input
											checked={includeUnstaged}
											disabled={isBusy || !isRepo}
											type="checkbox"
											onChange={() => {
												setIncludeUnstaged((current) => !current);
											}}
										/>
										<CheckSquare2 className="h-3 w-3 opacity-70" />
										Include unstaged changes
									</label>

									<div className="flex flex-wrap gap-2">
										<Button className="h-8" disabled={!canCommit} type="submit">
											{isCommitting ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : "Commit"}
										</Button>
										<Button
											className="h-8"
											disabled={!canCommit}
											onClick={handleCommitAndPush}
											type="button"
											variant="secondary"
										>
											Commit and push
										</Button>
									</div>
								</form>

								{actionError ? <p className="text-rose-200">{actionError}</p> : null}
								{actionFeedback ? <p className="text-sky-200">{actionFeedback}</p> : null}
							</>
						) : (
							<div className="space-y-2 rounded-md border border-white/10 px-2 py-2 text-xs text-slate-400">
								{status ? <p>This folder is not a git repository.</p> : <p>No git status available yet.</p>}
							</div>
						)}
					</div>
				</div>
			) : null}
		</div>
	);
};
