import { ChangeEvent, FormEvent, KeyboardEvent, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { ArrowUp, Loader2 } from "lucide-react";
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

	return (
		<section className={cn(focusMode ? "w-full" : "rounded-[24px] border border-white/10 bg-slate-950/65 p-3 backdrop-blur-2xl")}>
			<form className={cn(focusMode ? "space-y-2" : "space-y-3")} onSubmit={submit}>
				{focusMode ? (
					<div className="relative">
						<div
							className={cn(
								"rounded-[1.6rem] border border-white/10 bg-slate-900/70 px-3 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]",
								isLocked ? "opacity-85" : "",
							)}
						>
							<Textarea
								aria-label="Message input"
								className={cn(
									"min-h-[74px] max-h-[300px] resize-none border-0 bg-transparent px-1 py-1 pr-12 text-[15px] leading-7 text-slate-100 placeholder:text-slate-500 focus-visible:ring-0 disabled:cursor-not-allowed",
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
						</div>
						<div className="absolute right-2 bottom-2">
							<motion.div whileTap={shouldReduceMotion ? undefined : { scale: 0.97 }}>
								<Button
									aria-label={buttonLabel}
									className="h-10 w-10 rounded-full p-0 shadow-[0_10px_24px_rgba(56,189,248,0.25)]"
									disabled={submitDisabled}
									type="submit"
								>
									{sending || isRunning ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowUp className="h-4 w-4" />}
								</Button>
							</motion.div>
						</div>
					</div>
				) : (
					<div
						className={cn(
							"rounded-[1.6rem] border border-white/10 bg-slate-900/70 px-3 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]",
							isLocked ? "opacity-85" : "",
						)}
					>
						<Textarea
							aria-label="Message input"
							className={cn(
								"min-h-[92px] resize-y border-0 bg-transparent px-1 py-1 text-sm leading-6 text-slate-100 placeholder:text-slate-500 focus-visible:ring-0 disabled:cursor-not-allowed",
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
					</div>
				)}
				<div className="grid gap-2 px-1 sm:grid-cols-3">
					<div className="flex items-center justify-between gap-3 sm:flex-col sm:items-start sm:gap-1.5">
						<label className="text-[11px] uppercase tracking-[0.16em] text-slate-400" htmlFor={modelSelectId}>
							Model
						</label>
						<select
							className="h-8 w-full min-w-[160px] rounded-lg border border-white/15 bg-slate-900/70 px-2 text-xs text-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/35 disabled:cursor-not-allowed disabled:opacity-70"
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
					</div>
					<div className="flex items-center justify-between gap-3 sm:flex-col sm:items-start sm:gap-1.5">
						<label
							className="text-[11px] uppercase tracking-[0.16em] text-slate-400"
							htmlFor={reasoningSelectId}
						>
							Reasoning
						</label>
						<select
							className="h-8 w-full min-w-[160px] rounded-lg border border-white/15 bg-slate-900/70 px-2 text-xs text-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/35 disabled:cursor-not-allowed disabled:opacity-70"
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
					</div>
					<div className="flex items-center justify-between gap-3 sm:flex-col sm:items-start sm:gap-1.5">
						<label
							className="text-[11px] uppercase tracking-[0.16em] text-slate-400"
							htmlFor={permissionSelectId}
						>
							Permissions
						</label>
						<select
							className="h-8 w-full min-w-[160px] rounded-lg border border-white/15 bg-slate-900/70 px-2 text-xs text-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/35 disabled:cursor-not-allowed disabled:opacity-70"
							disabled={isLocked}
							id={permissionSelectId}
							onChange={(event) => {
								onPermissionModeChange(event.target.value as CodexPermissionMode);
							}}
							value={permissionMode}
						>
							<option value="plan">Plan mode</option>
							<option value="default">Default mode</option>
							<option value="full">Full access</option>
						</select>
					</div>
				</div>
				{!focusMode && (
					<div aria-live="polite" className="flex flex-wrap items-center justify-between gap-3">
						<span className={cn("text-xs", validationError ? "text-rose-300" : "text-slate-400")}>
							{statusText}
						</span>
						<motion.div whileTap={shouldReduceMotion ? undefined : { scale: 0.98 }}>
							<Button className="min-w-[112px] gap-2 rounded-xl" disabled={submitDisabled} type="submit">
								{buttonLabel}
								{sending || isRunning ? (
									<Loader2 className="h-4 w-4 animate-spin" />
								) : (
									<ArrowUp className="h-4 w-4" />
								)}
							</Button>
						</motion.div>
					</div>
				)}
			</form>
		</section>
	);
};
