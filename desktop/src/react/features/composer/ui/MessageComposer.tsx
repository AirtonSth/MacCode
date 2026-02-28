import { ChangeEvent, FormEvent, KeyboardEvent, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import { ArrowUp, Loader2 } from "lucide-react";
import { Button } from "../../../components/ui/button";
import { Textarea } from "../../../components/ui/textarea";
import { cn } from "../../../lib/utils";
import type { ChatStatus } from "../../workspace/model/useWorkspaceStore";

interface MessageComposerProps {
	disabled: boolean;
	sending: boolean;
	chatStatus: ChatStatus | null;
	onSend: (text: string) => void;
}

const MAX_MESSAGE_LENGTH = 4000;

export const MessageComposer = ({
	disabled,
	sending,
	chatStatus,
	onSend,
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

	const submitDisabled = isLocked || hasValidationError;
	const buttonLabel = isRunning ? "Wait" : sending ? "Sending..." : "Send";

	return (
		<section className="rounded-[24px] border border-white/10 bg-slate-950/65 p-3 backdrop-blur-2xl">
			<form className="space-y-3" onSubmit={submit}>
				<div
					className={cn(
						"rounded-2xl border border-white/10 bg-slate-900/70 px-3 py-2 shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]",
						isLocked ? "opacity-85" : "",
					)}
				>
					<Textarea
						aria-label="Message input"
						className="min-h-[92px] resize-y border-0 bg-transparent px-1 py-1 text-sm leading-6 text-slate-100 placeholder:text-slate-500 focus-visible:ring-0 disabled:cursor-not-allowed"
						disabled={isLocked}
						maxLength={MAX_MESSAGE_LENGTH}
						onChange={handleInputChange}
						onKeyDown={handleInputKeyDown}
						placeholder={
							disabled
								? "Select a chat to start."
								: isRunning
									? "Waiting for assistant response..."
									: "Type a message to the coding assistant"
						}
						rows={3}
						value={value}
					/>
				</div>
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
			</form>
		</section>
	);
};
