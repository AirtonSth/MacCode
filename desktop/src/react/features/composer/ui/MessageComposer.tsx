import { ChangeEvent, DragEvent, FormEvent, KeyboardEvent, useEffect, useLayoutEffect, useRef, useState } from "react";
import { m, useReducedMotion } from "framer-motion";
import { ArrowUp, ChevronDown, Loader2, Plus, Square } from "lucide-react";
import { Button } from "../../../components/ui/button";
import { Textarea } from "../../../components/ui/textarea";
import { cn } from "../../../lib/utils";
import { GitBranchControl } from "../../git/ui/GitBranchControl";
import type { ChatStatus } from "../../workspace/model/useWorkspaceStore";
import type { GitBranchDTO } from "../../../shared/api/remotecode-http";
import type { CodexPermissionMode } from "../../../../shared/codex-permission-mode";
import {
	appendAttachmentPathsToMessage,
	extractAttachmentPathsFromDataTransfer,
	extractAttachmentPathsFromPickerResult,
	normalizeAttachmentPath,
} from "../model/attachment-paths";
import { normalizeDeadKeyCompositionValue } from "../model/dead-key-normalization";
import {
	formatCodexReasoningEffortLabel,
	type CodexModelDescriptor,
	type CodexReasoningEffort,
} from "../../../../shared/codex-model-config";

type SelectedProvider = "codex" | "claude";

interface MessageComposerProps {
	disabled: boolean;
	sending: boolean;
	chatStatus: ChatStatus | null;
	onSend: (text: string) => void;
	onForceStop?: () => Promise<void> | void;
	stopping?: boolean;
	permissionMode: CodexPermissionMode;
	onPermissionModeChange: (mode: CodexPermissionMode) => void;
	availableModels: CodexModelDescriptor[];
	modelsLoading?: boolean;
	selectedModel: string | null;
	onModelChange: (model: string) => void;
	selectedProvider: SelectedProvider;
	providerLocked?: boolean;
	onProviderChange: (provider: SelectedProvider) => void;
	availableReasoningEfforts: CodexReasoningEffort[];
	selectedReasoningEffort: CodexReasoningEffort | null;
	onReasoningEffortChange: (effort: CodexReasoningEffort) => void;
	gitBranches?: GitBranchDTO[];
	gitCurrentBranch?: string | null;
	gitChangedFiles?: number;
	gitAdded?: number;
	gitRemoved?: number;
	isGitLoading?: boolean;
	isGitRepository?: boolean | null;
	onCheckoutBranch?: (branch: string) => Promise<void> | void;
	onCreateBranch?: (name: string) => Promise<void> | void;
	onPickContextPaths?: () => Promise<unknown> | unknown;
	focusMode?: boolean;
	focusRequestId?: number;
	onSlashCommand?: (command: string, args: string) => boolean | Promise<boolean>;
	onNavigateChat?: (direction: "prev" | "next") => void;
}

export type SlashCommandId =
	| "clear"
	| "model"
	| "plan"
	| "status"
	| "fork";

export const KNOWN_SLASH_COMMANDS: { id: SlashCommandId; hint: string }[] = [
	{ id: "clear", hint: "Start a fresh chat in current project" },
	{ id: "model", hint: "Open model picker (command palette)" },
	{ id: "plan", hint: "Toggle plan permission mode" },
	{ id: "status", hint: "Show status overview" },
	{ id: "fork", hint: "Fork this chat into a new one" },
];

const SLASH_COMMAND_REGEX = /^\/([a-z][a-z0-9-]*)(?:\s+(.*))?$/s;

const parseSlashCommand = (value: string): { command: string; args: string } | null => {
	const trimmed = value.trim();
	if (!trimmed.startsWith("/")) return null;
	const match = SLASH_COMMAND_REGEX.exec(trimmed);
	if (!match) return null;
	const [, command, args] = match;
	return { command: command.toLowerCase(), args: args?.trim() ?? "" };
};

const estimateTokenCount = (value: string): number => {
	if (value.length === 0) return 0;
	return Math.max(1, Math.ceil(value.length / 4));
};

export const MessageComposer = ({
	disabled,
	sending,
	chatStatus,
	onSend,
	onForceStop,
	stopping = false,
	availableModels,
	modelsLoading = false,
	selectedModel,
	onModelChange,
	selectedProvider,
	providerLocked = false,
	onProviderChange,
	availableReasoningEfforts,
	selectedReasoningEffort,
	onReasoningEffortChange,
	gitBranches = [],
	gitCurrentBranch = null,
	gitChangedFiles = 0,
	gitAdded = 0,
	gitRemoved = 0,
	isGitLoading = false,
	isGitRepository = null,
	onCheckoutBranch,
	onCreateBranch,
	onPickContextPaths,
	focusMode = false,
	focusRequestId = 0,
	onSlashCommand,
	onNavigateChat,
}: MessageComposerProps): JSX.Element => {
	const [value, setValue] = useState("");
	const textareaRef = useRef<HTMLTextAreaElement>(null);
	const fileInputRef = useRef<HTMLInputElement>(null);
	const appliedFocusRequestIdRef = useRef(0);
	const deadKeySequenceRef = useRef(false);
	const isComposingRef = useRef(false);
	const [validationError, setValidationError] = useState<string | null>(null);
	const [isDraggingPaths, setIsDraggingPaths] = useState(false);
	const [isComposing, setIsComposing] = useState(false);
	const shouldReduceMotion = useReducedMotion();
	const isRunning = chatStatus === "running";
	const isInputLocked = disabled || sending || isRunning;
	const hasText = value.trim().length > 0;
	const hasValidationError = !hasText;

	const validate = (): string | null => {
		if (!hasText) {
			return "Type a message before sending.";
		}

		return null;
	};

	const send = async () => {
		if (isInputLocked) {
			return;
		}

		const error = validate();
		if (error) {
			setValidationError(error);
			return;
		}

		const trimmed = value.trim();
		const slash = parseSlashCommand(trimmed);
		if (slash && onSlashCommand) {
			const handled = await onSlashCommand(slash.command, slash.args);
			if (handled) {
				setValue("");
				setValidationError(null);
				return;
			}
			setValidationError(`Unknown command: /${slash.command}`);
			return;
		}

		onSend(trimmed);
		setValue("");
		setValidationError(null);
	};

	const appendPathsToComposer = (paths: string[]) => {
		setValue((currentValue) => appendAttachmentPathsToMessage(currentValue, paths));
		if (validationError) {
			setValidationError(null);
		}
	};

	const handleAttachContextClick = async () => {
		if (isInputLocked) {
			return;
		}

		if (onPickContextPaths) {
			try {
				const pickerResult = await onPickContextPaths();
				const pickedPaths = extractAttachmentPathsFromPickerResult(pickerResult);
				if (pickedPaths.length > 0) {
					appendPathsToComposer(pickedPaths);
				}
			} catch {
				// native picker unavailable
			}

			return;
		}

		fileInputRef.current?.click();
	};

	const handleAttachInputChange = (event: ChangeEvent<HTMLInputElement>) => {
		const files = event.target.files;
		if (!files || files.length === 0) {
			return;
		}

		const pickedPaths: string[] = [];
		for (let index = 0; index < files.length; index += 1) {
			const fileWithPath = files[index] as File & { path?: string };
			const maybePath = fileWithPath.path;
			if (typeof maybePath !== "string") {
				continue;
			}

			const normalized = normalizeAttachmentPath(maybePath);
			if (normalized) {
				pickedPaths.push(normalized);
			}
		}

		appendPathsToComposer(pickedPaths);
		event.target.value = "";
	};

	const handleDragEnter = (event: DragEvent<HTMLDivElement>) => {
		if (isInputLocked) {
			return;
		}

		const draggedPaths = extractAttachmentPathsFromDataTransfer(event.dataTransfer);
		if (draggedPaths.length === 0) {
			return;
		}

		event.preventDefault();
		setIsDraggingPaths(true);
	};

	const handleDragOver = (event: DragEvent<HTMLDivElement>) => {
		if (isInputLocked) {
			return;
		}

		const draggedPaths = extractAttachmentPathsFromDataTransfer(event.dataTransfer);
		if (draggedPaths.length === 0) {
			return;
		}

		event.preventDefault();
		event.dataTransfer.dropEffect = "copy";
		setIsDraggingPaths(true);
	};

	const handleDragLeave = (event: DragEvent<HTMLDivElement>) => {
		const relatedTarget = event.relatedTarget;
		if (relatedTarget && event.currentTarget.contains(relatedTarget as Node)) {
			return;
		}

		setIsDraggingPaths(false);
	};

	const handleDrop = (event: DragEvent<HTMLDivElement>) => {
		setIsDraggingPaths(false);
		if (isInputLocked) {
			return;
		}

		const droppedPaths = extractAttachmentPathsFromDataTransfer(event.dataTransfer);
		if (droppedPaths.length === 0) {
			return;
		}

		event.preventDefault();
		appendPathsToComposer(droppedPaths);
	};

	const submit = (event: FormEvent<HTMLFormElement>) => {
		event.preventDefault();
		void send();
	};

	const handleInputChange = (event: ChangeEvent<HTMLTextAreaElement>) => {
		const nextValue = normalizeDeadKeyCompositionValue(event.target.value);
		event.target.value = nextValue;

		setValue(nextValue);
		if (validationError) {
			setValidationError(null);
		}
	};

	useLayoutEffect(() => {
		if (isComposing) {
			return;
		}

		const textarea = textareaRef.current;
		if (!textarea) {
			return;
		}
		const rafId = requestAnimationFrame(() => {
			textarea.style.height = "auto";
			textarea.style.height = `${Math.min(textarea.scrollHeight, 220)}px`;
		});
		return () => cancelAnimationFrame(rafId);
	}, [isComposing, value]);

	useEffect(() => {
		if (focusRequestId <= appliedFocusRequestIdRef.current || isInputLocked) {
			return;
		}

		appliedFocusRequestIdRef.current = focusRequestId;
		const rafId = requestAnimationFrame(() => {
			textareaRef.current?.focus({ preventScroll: true });
		});
		return () => cancelAnimationFrame(rafId);
	}, [focusRequestId, isInputLocked]);

	const handleInputKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
		if (event.key === "Dead" || event.key === "Process") {
			deadKeySequenceRef.current = true;
			return;
		}

		if (isComposing || isComposingRef.current || event.nativeEvent.isComposing) {
			return;
		}

		if (event.metaKey || event.ctrlKey) {
			const shortcutKey = event.key.toLowerCase();
			if (shortcutKey === "a") {
				event.preventDefault();
				textareaRef.current?.select();
				return;
			}

			return;
		}

		if ((event.key === "ArrowUp" || event.key === "ArrowDown") && onNavigateChat) {
			if (!hasText) {
				event.preventDefault();
				onNavigateChat(event.key === "ArrowUp" ? "prev" : "next");
				return;
			}
		}

		if (event.key !== "Enter") {
			return;
		}

		if (!event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
			event.preventDefault();
			void send();
		}
	};

	const tokenEstimate = estimateTokenCount(value);
	const statusText =
		isRunning
			? (stopping ? "Stopping thread..." : "Assistant is running. Force stop to interrupt.")
			: sending
				? "Sending message..."
				: validationError ?? (hasText
					? `~${tokenEstimate} tok · ${value.length} chars`
					: "Type a message to send. Try /clear, /model, /status…");
	const modelSelectId = focusMode ? "model-focus" : "model";
	const reasoningSelectId = focusMode ? "reasoning-focus" : "reasoning";

	const submitDisabled = isInputLocked || hasValidationError;
	const forceStopDisabled = disabled || sending || stopping || !onForceStop;
	const actionDisabled = isRunning ? forceStopDisabled : submitDisabled;
	const buttonLabel = isRunning ? (stopping ? "Stopping..." : "Force Stop") : sending ? "Sending..." : "Send";
	const composerTextClass = "text-sm leading-6 text-[#e5e7eb]";
	const subtleSelectClass =
		"h-6 appearance-none bg-transparent px-1 pr-4 text-xs font-normal leading-4 text-[#9a9da5] transition-colors hover:text-[#c8ccd6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/60 focus-visible:ring-offset-2 focus-visible:ring-offset-[#181a1f] disabled:cursor-not-allowed disabled:opacity-50";
	const showModelsLoadingState = modelsLoading && availableModels.length === 0;
	const handlePrimaryAction = () => {
		if (isRunning) {
			if (forceStopDisabled) {
				return;
			}

			void onForceStop?.();
			return;
		}

		send();
	};

	return (
		<section className={cn(focusMode ? "w-full" : "rounded-[24px] border border-white/10 bg-slate-950/65 p-3 backdrop-blur-2xl")}>
			<form className={cn(focusMode ? "space-y-0" : "space-y-2")} onSubmit={submit}>
				<div
					className={cn(
						`codex-sidebar rounded-2xl border border-[#2c3038] bg-[linear-gradient(180deg,#181a1f_0%,#15171b_100%)] px-4 pb-1 pt-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.04),_0_16px_30px_rgba(0,0,0,0.35)] ${composerTextClass}`,
						isDraggingPaths ? "border-sky-300/70 bg-[linear-gradient(180deg,#1b2029_0%,#171b24_100%)]" : "",
						isInputLocked ? "opacity-85" : "",
					)}
					onDragEnter={handleDragEnter}
					onDragLeave={handleDragLeave}
					onDragOver={handleDragOver}
					onDrop={handleDrop}
				>
					<input
						aria-hidden={true}
						className="hidden"
						multiple
						onChange={handleAttachInputChange}
						ref={fileInputRef}
						tabIndex={-1}
						type="file"
					/>

					<Textarea
						ref={textareaRef}
						aria-label="Message input"
						className={cn(
							`min-h-[56px] max-h-[220px] select-text resize-none overflow-y-auto border-0 bg-transparent px-0 py-0 ${composerTextClass} placeholder:text-[#5f636c] focus-visible:ring-0 focus-visible:ring-offset-0 focus-visible:shadow-none disabled:cursor-not-allowed`,
						)}
						disabled={isInputLocked}
						onChange={handleInputChange}
						onCompositionEnd={() => {
							deadKeySequenceRef.current = false;
							isComposingRef.current = false;
							setIsComposing(false);
						}}
						onCompositionStart={() => {
							deadKeySequenceRef.current = true;
							isComposingRef.current = true;
							setIsComposing(true);
						}}
						onKeyDown={handleInputKeyDown}
						placeholder={
							disabled
								? "Select a project to start."
								: isRunning
									? "Waiting for assistant response..."
									: "Ask for follow-up changes"
						}
						rows={2}
						value={value}
					/>

					<div className={cn("mt-1 flex items-center justify-between gap-2 border-t border-[#2b3038] pt-1", composerTextClass)}>
						<div className="flex min-w-0 flex-1 items-center gap-1">
							<Button
								aria-label="Attach context"
								className="h-6 w-6 shrink-0 rounded-full p-0 text-[#9a9da5] hover:bg-white/[0.04] hover:text-[#c8ccd6]"
								disabled={isInputLocked}
								onClick={() => {
									void handleAttachContextClick();
								}}
								size="icon"
								type="button"
								variant="ghost"
							>
								<Plus className="h-3 w-3" />
							</Button>

							<div className="relative shrink-0">
								<select
									aria-label="Provider"
									className={cn(subtleSelectClass, "min-w-[68px]")}
									disabled={isInputLocked || providerLocked}
									id={focusMode ? "provider-focus" : "provider"}
									onChange={(event) => {
										onProviderChange(event.target.value as SelectedProvider);
									}}
									value={selectedProvider}
								>
									<option value="codex">Codex</option>
									<option value="claude">Claude Code</option>
								</select>
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3 w-3 -translate-y-1/2 text-[#7a7f89]" />
							</div>

						<div className="relative shrink-0">
							<select
									aria-label="Model"
									className={cn(subtleSelectClass, "min-w-[180px]")}
								disabled={isInputLocked || modelsLoading || availableModels.length === 0}
									id={modelSelectId}
									onChange={(event) => {
										onModelChange(event.target.value);
									}}
									value={selectedModel ?? ""}
								>
									{modelsLoading ? <option value="">Loading models...</option> : null}
									{!modelsLoading && selectedModel === null ? <option value="">Select model</option> : null}
									{!showModelsLoadingState && availableModels.length === 0 ? <option value="">No models</option> : null}
									{availableModels.map((model) => (
										<option key={model.id} value={model.model}>
											{model.displayName}
										</option>
									))}
								</select>
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3 w-3 -translate-y-1/2 text-[#7a7f89]" />
							</div>

							<div className="relative shrink-0">
							<select
									aria-label="Reasoning"
									className={cn(subtleSelectClass, "min-w-[80px]")}
								disabled={isInputLocked || availableReasoningEfforts.length === 0}
									id={reasoningSelectId}
									onChange={(event) => {
										onReasoningEffortChange(event.target.value as CodexReasoningEffort);
									}}
									value={selectedReasoningEffort ?? availableReasoningEfforts[0] ?? ""}
								>
									{availableReasoningEfforts.length === 0 ? <option value="">No reasoning levels</option> : null}
									{availableReasoningEfforts.map((effort) => (
										<option key={effort} value={effort}>
											{formatCodexReasoningEffortLabel(effort)}
										</option>
									))}
								</select>
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3 w-3 -translate-y-1/2 text-[#7a7f89]" />
							</div>

							</div>

						<div className="flex items-center gap-1">
							{onCheckoutBranch && onCreateBranch ? (
								<div className="shrink-0">
								<GitBranchControl
										branches={gitBranches}
										currentBranch={gitCurrentBranch}
										changedFiles={gitChangedFiles}
										added={gitAdded}
										removed={gitRemoved}
									disabled={isInputLocked}
										isLoading={isGitLoading}
										isGitRepository={isGitRepository}
										onCheckoutBranch={onCheckoutBranch}
										onCreateBranch={onCreateBranch}
									/>
								</div>
							) : null}
						</div>

						<m.div className="ml-1" whileTap={shouldReduceMotion ? undefined : { scale: 0.97 }}>
							<Button
								aria-label={buttonLabel}
								className={cn(
									"h-8 w-8 shrink-0 rounded-full p-0 shadow-none transition-colors duration-200",
									isRunning
										? "bg-rose-500 text-rose-50 hover:bg-rose-400"
										: "bg-[#aeb2bb] text-[#181a20] hover:bg-[#c0c5ce]",
								)}
								disabled={actionDisabled}
								onClick={handlePrimaryAction}
								type={isRunning ? "button" : "submit"}
							>
								{isRunning
									? (stopping ? <Loader2 className="h-4 w-4 animate-spin" /> : <Square className="h-3.5 w-3.5" />)
									: (sending ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-4 w-4" />)}
							</Button>
						</m.div>
					</div>
				</div>

				{!focusMode && (
					<div aria-live="polite" className="px-1">
						<span
							className={cn(composerTextClass, validationError ? "text-rose-300" : "text-slate-400/90")}
							style={{ transition: "opacity 200ms ease" }}
						>
							{statusText}
						</span>
					</div>
				)}
			</form>
		</section>
	);
};
