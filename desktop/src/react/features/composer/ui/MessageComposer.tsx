import { ChangeEvent, FormEvent, KeyboardEvent, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { ArrowUp, ChevronDown, Loader2, Plus } from "lucide-react";
import { Button } from "../../../components/ui/button";
import { Textarea } from "../../../components/ui/textarea";
import { cn } from "../../../lib/utils";
import type { ChatStatus } from "../../workspace/model/useWorkspaceStore";
import type { CodexPermissionMode } from "../../../../shared/codex-permission-mode";
import {
	formatCodexReasoningEffortLabel,
	type CodexModelDescriptor,
	type CodexReasoningEffort,
} from "../../../../shared/codex-model-config";

interface MessageComposerProps {
	disabled: boolean;
	sending: boolean;
	chatStatus: ChatStatus | null;
	onSend: (text: string) => void;
	permissionMode: CodexPermissionMode;
	onPermissionModeChange: (mode: CodexPermissionMode) => void;
	availableModels: CodexModelDescriptor[];
	selectedModel: string | null;
	onModelChange: (model: string) => void;
	availableReasoningEfforts: CodexReasoningEffort[];
	selectedReasoningEffort: CodexReasoningEffort | null;
	onReasoningEffortChange: (effort: CodexReasoningEffort) => void;
	focusMode?: boolean;
}

const MAX_MESSAGE_LENGTH = 4000;

export const MessageComposer = ({
	disabled,
	sending,
	chatStatus,
	onSend,
	permissionMode,
	onPermissionModeChange,
	availableModels,
	selectedModel,
	onModelChange,
	availableReasoningEfforts,
	selectedReasoningEffort,
	onReasoningEffortChange,
	focusMode = false,
}: MessageComposerProps): JSX.Element => {
	const [value, setValue] = useState("");
	const [validationError, setValidationError] = useState<string | null>(null);
	const shouldReduceMotion = useReducedMotion();
	const isRunning = chatStatus === "running";
	const isLocked = disabled || sending || isRunning;
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
		if (isLocked) {
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
			? "Assistant is running. Wait for it to finish."
			: sending
				? "Sending message..."
				: validationError ?? (hasText ? `${value.length}/${MAX_MESSAGE_LENGTH}` : "Type a message to send.");
	const permissionSelectId = focusMode ? "permission-mode-focus" : "permission-mode";
	const modelSelectId = focusMode ? "model-focus" : "model";
	const reasoningSelectId = focusMode ? "reasoning-focus" : "reasoning";

	const submitDisabled = isLocked || hasValidationError;
	const buttonLabel = isRunning ? "Wait" : sending ? "Sending..." : "Send";
	const subtleSelectClass =
		"h-7 appearance-none bg-transparent px-1 pr-5 text-[13px] text-slate-400 transition-colors hover:text-slate-200 focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-50";

	return (
		<section className={cn(focusMode ? "w-full" : "rounded-[24px] border border-white/10 bg-slate-950/65 p-3 backdrop-blur-2xl")}>
			<form className={cn(focusMode ? "space-y-0" : "space-y-2")} onSubmit={submit}>
				<div
					className={cn(
						"rounded-[1.6rem] border border-white/10 bg-slate-900/70 px-3 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.08),_0_16px_30px_rgba(0,0,0,0.32)]",
						isLocked ? "opacity-85" : "",
					)}
				>
					<Textarea
						aria-label="Message input"
						className={cn(
							focusMode
								? "min-h-[74px] max-h-[300px] resize-none border-0 bg-transparent px-1 py-1 text-[15px] leading-7 text-slate-100 placeholder:text-slate-500 focus-visible:ring-0 focus-visible:ring-offset-0 focus-visible:shadow-none disabled:cursor-not-allowed"
								: "min-h-[92px] max-h-[300px] resize-none border-0 bg-transparent px-1 py-1 text-sm leading-6 text-slate-100 placeholder:text-slate-500 focus-visible:ring-0 focus-visible:ring-offset-0 focus-visible:shadow-none disabled:cursor-not-allowed",
						)}
						disabled={isLocked}
						maxLength={MAX_MESSAGE_LENGTH}
						onChange={handleInputChange}
						onKeyDown={handleInputKeyDown}
						placeholder={
							disabled
								? "Select a project to start."
								: isRunning
									? "Waiting for assistant response..."
									: "Type a message to the coding assistant"
						}
						rows={3}
						value={value}
					/>

					<div className="mt-2 flex items-center justify-between gap-2 border-t border-white/10 pt-2">
						<div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
							<Button
								aria-label="Attach context"
								className="h-7 w-7 shrink-0 rounded-full p-0 text-slate-400 hover:bg-white/[0.04] hover:text-slate-100"
								disabled={isLocked}
								size="icon"
								type="button"
								variant="ghost"
							>
								<Plus className="h-4 w-4" />
							</Button>

							<div className="relative shrink-0">
								<select
									aria-label="Model"
									className={cn(subtleSelectClass, "min-w-[180px]")}
									disabled={isLocked || availableModels.length === 0}
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
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-500" />
							</div>

							<div className="relative shrink-0">
								<select
									aria-label="Reasoning"
									className={cn(subtleSelectClass, "min-w-[132px]")}
									disabled={isLocked || availableReasoningEfforts.length === 0}
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
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-500" />
							</div>

							<div className="relative shrink-0">
								<select
									aria-label="Permission mode"
									className={cn(subtleSelectClass, "min-w-[128px]")}
									disabled={isLocked}
									id={permissionSelectId}
									onChange={(event) => {
										onPermissionModeChange(event.target.value as CodexPermissionMode);
									}}
									value={permissionMode}
								>
									<option value="plan">Plan</option>
									<option value="default">Default</option>
									<option value="full">Full access</option>
								</select>
								<ChevronDown className="pointer-events-none absolute right-0 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-500" />
							</div>
						</div>

						<motion.div whileTap={shouldReduceMotion ? undefined : { scale: 0.97 }}>
							<Button
								aria-label={buttonLabel}
								className="h-10 w-10 shrink-0 rounded-full bg-white p-0 text-slate-900 shadow-[0_12px_26px_rgba(0,0,0,0.35)] hover:bg-white/90"
								disabled={submitDisabled}
								type="submit"
							>
								{sending || isRunning ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-4 w-4" />}
							</Button>
						</motion.div>
					</div>
				</div>

				{!focusMode && (
					<div aria-live="polite" className="px-1">
						<span className={cn("text-xs", validationError ? "text-rose-300" : "text-slate-400/90")}>
							{statusText}
						</span>
					</div>
				)}
			</form>
		</section>
	);
};
