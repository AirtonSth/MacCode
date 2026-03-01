import { useEffect, useMemo, useRef, useState } from "react";
import { Check, ChevronDown, GitBranch, Loader2, Plus, Search } from "lucide-react";

import type { GitBranchDTO } from "../../../shared/api/remotecode-http";
import { cn } from "../../../lib/utils";

interface GitBranchControlProps {
	branches: GitBranchDTO[];
	currentBranch: string | null;
	changedFiles?: number;
	added?: number;
	removed?: number;
	disabled?: boolean;
	isLoading?: boolean;
	isGitRepository: boolean | null;
	onCheckoutBranch: (branch: string) => Promise<void> | void;
	onCreateBranch: (name: string) => Promise<void> | void;
}

export const GitBranchControl = ({
	branches,
	currentBranch,
	changedFiles = 0,
	added = 0,
	removed = 0,
	disabled = false,
	isLoading = false,
	isGitRepository,
	onCheckoutBranch,
	onCreateBranch,
}: GitBranchControlProps): JSX.Element => {
	const containerRef = useRef<HTMLDivElement | null>(null);
	const [isOpen, setIsOpen] = useState(false);
	const [searchTerm, setSearchTerm] = useState("");
	const [isCreateMode, setIsCreateMode] = useState(false);
	const [newBranchName, setNewBranchName] = useState("");
	const [isSubmitting, setIsSubmitting] = useState(false);
	const [errorMessage, setErrorMessage] = useState<string | null>(null);

	const normalizedFilter = searchTerm.trim().toLowerCase();
	const repoReady = isGitRepository === true;
	const isActionDisabled = disabled || isLoading || isSubmitting || !repoReady;

	const filteredBranches = useMemo(
		() =>
			branches.filter((branch) => {
				if (normalizedFilter.length === 0) {
					return true;
				}

				return branch.toLowerCase().includes(normalizedFilter);
			}),
		[branches, normalizedFilter],
	);

	useEffect(() => {
		if (!isOpen) {
			return;
		}

		const handlePointerDown = (event: MouseEvent) => {
			if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
				setIsOpen(false);
				setSearchTerm("");
				setIsCreateMode(false);
				setNewBranchName("");
				setErrorMessage(null);
			}
		};

		const handleEscape = (event: KeyboardEvent) => {
			if (event.key === "Escape") {
				setIsOpen(false);
				setSearchTerm("");
				setIsCreateMode(false);
				setNewBranchName("");
				setErrorMessage(null);
			}
		};

		window.addEventListener("mousedown", handlePointerDown);
		window.addEventListener("keydown", handleEscape);
		return () => {
			window.removeEventListener("mousedown", handlePointerDown);
			window.removeEventListener("keydown", handleEscape);
		};
	}, [isOpen]);

	const handleCheckout = async (branch: string) => {
		if (!branch || isActionDisabled) {
			return;
		}

		setErrorMessage(null);
		setIsSubmitting(true);
		try {
			await Promise.resolve(onCheckoutBranch(branch));
			setIsOpen(false);
			setSearchTerm("");
			setIsCreateMode(false);
			setNewBranchName("");
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to checkout branch.");
		} finally {
			setIsSubmitting(false);
		}
	};

	const handleCreate = async () => {
		if (isActionDisabled) {
			return;
		}

		const normalizedBranchName = newBranchName.trim();
		if (normalizedBranchName.length === 0) {
			return;
		}

		setErrorMessage(null);
		setIsSubmitting(true);
		try {
			await Promise.resolve(onCreateBranch(normalizedBranchName));
			setIsOpen(false);
			setSearchTerm("");
			setIsCreateMode(false);
			setNewBranchName("");
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to create branch.");
		} finally {
			setIsSubmitting(false);
		}
	};

	return (
		<div className="relative shrink-0" ref={containerRef}>
			<div className="flex items-center gap-2">
				<button
					aria-expanded={isOpen}
					aria-haspopup="dialog"
					className={cn(
						"inline-flex h-10 items-center gap-2 rounded-full border border-white/10 bg-white/[0.08] px-3.5 text-sm text-[#b7bcc6] transition hover:border-white/20 hover:bg-white/[0.12] hover:text-[#eceff4] disabled:cursor-not-allowed disabled:opacity-50",
						isOpen ? "border-white/25 bg-white/[0.14] text-[#eceff4]" : "",
					)}
					disabled={disabled || isSubmitting}
					onClick={() => {
						if (isGitRepository !== true || isSubmitting) {
							return;
						}

						setIsOpen((current) => {
							const next = !current;
							if (!next) {
								setSearchTerm("");
								setIsCreateMode(false);
								setNewBranchName("");
							}
							return next;
						});
						setErrorMessage(null);
					}}
					type="button"
				>
					<GitBranch className="h-4 w-4" />
					<span className="max-w-[130px] truncate font-medium">{currentBranch ?? "Branches"}</span>
					<ChevronDown className={cn("h-4 w-4 transition-transform", isOpen ? "rotate-180" : "")} />
				</button>

				{isLoading || isSubmitting ? <Loader2 className="h-5 w-5 animate-spin text-[#959ba6]" /> : null}
			</div>

			{isOpen ? (
				<div className="absolute bottom-[calc(100%+12px)] left-0 z-[70] w-[380px] rounded-[22px] border border-white/10 bg-[linear-gradient(145deg,rgba(40,41,45,0.98),rgba(24,25,29,0.98))] p-3 shadow-[0_28px_80px_rgba(0,0,0,0.56)] backdrop-blur-xl">
					<div className="rounded-2xl bg-white/[0.06] px-3 py-2">
						<div className="flex items-center gap-2 text-[#9ca1ab]">
							<Search className="h-4 w-4" />
							<input
								aria-label="Search branches"
								autoFocus
								className="h-7 w-full bg-transparent text-[16px] font-medium text-[#d7dbe2] outline-none placeholder:text-[#989da7]"
								disabled={isActionDisabled}
								onChange={(event) => {
									setSearchTerm(event.target.value);
								}}
								placeholder="Search branches"
								type="text"
								value={searchTerm}
							/>
						</div>
					</div>

					<p className="px-2 pb-1 pt-4 text-sm font-medium text-[#9ca1aa]">Branches</p>

					<div className="max-h-[280px] space-y-0.5 overflow-y-auto px-1 pb-2">
						{filteredBranches.length === 0 ? (
							<div className="px-3 py-3 text-sm text-[#8f959f]">
								{isLoading ? "Loading local branches..." : "No local branches match your search"}
							</div>
						) : (
							filteredBranches.map((branch) => {
								const isCurrent = branch === currentBranch;
								return (
									<button
										className={cn(
											"w-full rounded-xl px-2 py-2 text-left transition",
											isCurrent ? "bg-white/[0.03]" : "hover:bg-white/[0.04]",
										)}
										key={branch}
										onClick={() => {
											void handleCheckout(branch);
										}}
										type="button"
									>
										<div className="flex items-center justify-between gap-3">
											<div className="min-w-0">
												<div className="flex items-center gap-2">
													<GitBranch className="h-4 w-4 text-[#d6d9e0]" />
													<span className="truncate text-[16px] font-semibold text-[#edf0f4]">{branch}</span>
												</div>

												{isCurrent ? (
													<p className="pl-6 text-[14px] text-[#8f949d]">
														Uncommited: {changedFiles} files{" "}
														<span className="font-semibold text-emerald-400">+{added}</span>{" "}
														<span className="font-semibold text-rose-400">-{removed}</span>
													</p>
												) : null}
											</div>

											{isCurrent ? <Check className="h-5 w-5 shrink-0 text-[#f5f7fb]" /> : null}
										</div>
									</button>
								);
							})
						)}
					</div>

					<div className="mt-2 border-t border-white/10 pt-2">
						{isCreateMode ? (
							<div className="space-y-2 px-1">
								<input
									aria-label="New branch name"
									autoFocus
									className="h-9 w-full rounded-xl border border-white/15 bg-white/[0.06] px-3 text-sm text-[#e4e8ef] outline-none placeholder:text-[#9197a2] focus-visible:border-white/30"
									disabled={isActionDisabled}
									onChange={(event) => {
										setNewBranchName(event.target.value);
									}}
									onKeyDown={(event) => {
										if (event.key === "Enter") {
											event.preventDefault();
											void handleCreate();
										}
										if (event.key === "Escape") {
											event.preventDefault();
											setIsCreateMode(false);
											setNewBranchName("");
										}
									}}
									placeholder="new-branch-name"
									type="text"
									value={newBranchName}
								/>
								<div className="flex items-center justify-end gap-2">
									<button
										className="h-8 rounded-lg px-2.5 text-xs text-[#a8adb6] transition hover:bg-white/[0.06] hover:text-[#dfe3ea]"
										disabled={isActionDisabled}
										onClick={() => {
											setIsCreateMode(false);
											setNewBranchName("");
										}}
										type="button"
									>
										Cancel
									</button>
									<button
										className="h-8 rounded-lg bg-white/[0.12] px-3 text-xs font-medium text-[#edf1f6] transition hover:bg-white/[0.18] disabled:cursor-not-allowed disabled:opacity-50"
										disabled={isActionDisabled || newBranchName.trim().length === 0}
										onClick={() => {
											void handleCreate();
										}}
										type="button"
									>
										Create and checkout
									</button>
								</div>
							</div>
						) : (
							<button
								className="flex h-10 w-full items-center gap-2 rounded-xl px-2 text-left text-base font-medium text-[#eceff4] transition hover:bg-white/[0.04] disabled:cursor-not-allowed disabled:opacity-50"
								disabled={isActionDisabled}
								onClick={() => {
									setIsCreateMode(true);
									setNewBranchName(searchTerm.trim());
								}}
								type="button"
							>
								<Plus className="h-5 w-5 shrink-0" />
								<span className="truncate">Create and checkout new branch...</span>
							</button>
						)}
					</div>

					{errorMessage ? <p className="px-2 pt-2 text-xs text-rose-300">{errorMessage}</p> : null}
				</div>
			) : null}

			{isGitRepository === false ? (
				<p className="pt-1 text-[11px] text-rose-300">This project is not a git repository.</p>
			) : null}
		</div>
	);
};
