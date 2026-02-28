import type { ChatDTO, MessageDTO } from "../../workspace/model/useWorkspaceStore";

interface ConversationPanelProps {
	chat: ChatDTO | null;
	messages: MessageDTO[];
	streamingText: string;
	loading: boolean;
	hasRestError: boolean;
}

export const ConversationPanel = ({
	chat,
	messages,
	streamingText,
	loading,
	hasRestError,
}: ConversationPanelProps): JSX.Element => {
	const hasMessages = messages.length > 0;
	const hasStreaming = streamingText.trim().length > 0;
	const hasContent = hasMessages || hasStreaming;

	return (
		<section className="conversation-panel">
			<header className="panel-header">
				<div>
					<h2>{chat ? chat.title : "No chat selected"}</h2>
					{chat ? (
						<p className="small-muted">
							Status {chat.status} · +{chat.diffAdded} · -{chat.diffRemoved}
						</p>
					) : null}
				</div>
			</header>

			{loading ? <p className="small-muted">Loading messages…</p> : null}

			{!chat ? (
				<p className="empty-state">Select a chat to start a conversation.</p>
			) : null}

			{chat && !loading && !hasContent ? (
				<p className="empty-state">No messages yet. Send your first message.</p>
			) : null}

			{hasRestError ? (
				<p className="small-muted">Some data may be outdated. Check errors in the activity log.</p>
			) : null}

			{hasContent ? (
				<div className="message-list" aria-live="polite">
				{messages.map((message) => (
					<article
						className={`message-bubble ${message.role === "user" ? "user-message" : "assistant-message"}`}
						key={message.id}
					>
						<p>{message.content}</p>
						<span className="small-muted">{message.role}</span>
					</article>
				))}
				{streamingText ? (
					<article className="message-bubble assistant-message streaming">
						<p>{streamingText}</p>
						<span className="small-muted">assistant · streaming</span>
					</article>
				) : null}
				</div>
			) : null}
		</section>
	);
};
