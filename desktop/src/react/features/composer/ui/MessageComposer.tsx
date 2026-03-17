import { ChangeEvent, DragEvent, FormEvent, KeyboardEvent, useLayoutEffect, useRef, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
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
	selectedModel: string | null;
	onModelChange: (model: string) => void;
	selectedProvider: SelectedProvider;
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
}

const MAX_MESSAGE_LENGTH = 4000;

export const MessageComposer = ({
	disabled,
	sending,
	chatStatus,
	onSend,
	onForceStop,
	stopping = false,
	availableModels,
	selectedModel,
	onModelChange,
	selectedProvider,
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
}: MessageComposerProps): JSX.Element => {
	const [value, setValue] = useState("");
	const textareaRef = useRef<HTMLTextAreaElement>(null);
	const fileInputRef = useRef<HTMLInputElement>(null);
	const [validationError, setValidationError] = useState<string | null>(null);
	const [isDraggingPaths, setIsDraggingPaths] = useState(false);
	const shouldReduceMotion = useReducedMotion();
	const isRunning = chatStatus === "running";
	const isInputLocked = disabled || sending || isRunning;
	const hasText = value.trim().length > 0;
	const isOverLimit = value.length > MAX_MESSAGE_LENGTH;
	const hasValidationError = !hasText || isOverLimit;

	const validate = (): string | null => {
		if (!hasText) {
			return "Type a message before sending.";
		}

		if (isOverLimit) {
			return `Message is too long. Max ${MAX_MESSAGE_LENGTH} characters.`;
		}

		return null;
	};

	const send = () => {
		if (isInputLocked) {
			return;
		}

		const error = validate();
		if (error) {
			setValidationError(error);
			return;
		}

		onSend(value.trim());
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
		send();
	};

	const handleInputChange = (event: ChangeEvent<HTMLTextAreaElement>) => {
		setValue(event.target.value);
		if (validationError) {
			setValidationError(null);
		}
	};

	useLayoutEffect(() => {
		const textarea = textareaRef.current;
		if (!textarea) {
			return;
		}
		textarea.style.height = "auto";
		textarea.style.height = `${Math.min(textarea.scrollHeight, 220)}px`;
	}, [value]);

	const handleInputKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
		if (event.key !== "Enter") {
			return;
		}

		if (!event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey) {
			event.preventDefault();
			send();
		}
	};

	const statusText =
		isRunning
			? (stopping ? "Stopping thread..." : "Assistant is running. Force stop to interrupt.")
			: sending
				? "Sending message..."
				: validationError ?? (hasText ? `${value.length}/${MAX_MESSAGE_LENGTH}` : "Type a message to send.");
	const modelSelectId = focusMode ? "model-focus" : "model";
	const reasoningSelectId = focusMode ? "reasoning-focus" : "reasoning";

	const submitDisabled = isInputLocked || hasValidationError;
	const forceStopDisabled = disabled || sending || stopping || !onForceStop;
	const actionDisabled = isRunning ? forceStopDisabled : submitDisabled;
	const buttonLabel = isRunning ? (stopping ? "Stopping..." : "Force Stop") : sending ? "Sending..." : "Send";
	const composerTextClass = "text-sm leading-6 text-[#e5e7eb]";
	const subtleSelectClass =
		"h-6 appearance-none bg-transparent px-1 pr-4 text-xs leading-4 font-normal text-[#9a9da5] transition-colors hover:text-[#c8ccd6] focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-50";
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
							`min-h-[56px] max-h-[220px] select-text resize-none overflow-hidden border-0 bg-transparent px-0 py-0 ${composerTextClass} placeholder:text-[#5f636c] focus-visible:ring-0 focus-visible:ring-offset-0 focus-visible:shadow-none disabled:cursor-not-allowed`,
						)}
						disabled={isInputLocked}
						maxLength={MAX_MESSAGE_LENGTH}
						onChange={handleInputChange}
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
								disabled={isInputLocked}
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
								disabled={isInputLocked || availableModels.length === 0}
									id={modelSelectId}
									onChange={(event) => {
										onModelChange(event.target.value);
									}}
									value={selectedModel ?? availableModels[0]?.model ?? ""}
								>
									{availableModels.length === 0 ? <option value="">No models</option> : null}
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

						<motion.div className="ml-1" whileTap={shouldReduceMotion ? undefined : { scale: 0.97 }}>
							<Button
								aria-label={buttonLabel}
								className={cn(
									"h-8 w-8 shrink-0 rounded-full p-0 shadow-none",
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
						</motion.div>
					</div>
				</div>

				{!focusMode && (
					<div aria-live="polite" className="px-1">
						<span className={cn(composerTextClass, validationError ? "text-rose-300" : "text-slate-400/90")}>
							{statusText}
						</span>
					</div>
				)}
			</form>
		</section>
	);
};
