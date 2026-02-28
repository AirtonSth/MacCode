import { ChangeEvent, FormEvent, KeyboardEvent, useState } from "react";
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
		<section className="composer-panel">
			<form className="composer-form" onSubmit={submit}>
				<textarea
					aria-label="Message input"
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
				<div aria-live="polite" className="composer-actions">
					{statusText ? <span className="small-muted">{statusText}</span> : null}
					<button disabled={submitDisabled} type="submit">
						{buttonLabel}
					</button>
				</div>
			</form>
		</section>
	);
};
