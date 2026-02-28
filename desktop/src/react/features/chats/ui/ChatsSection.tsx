import { FormEvent, useState } from "react";

import type { ChatDTO } from "../../workspace/model/useWorkspaceStore";

interface ChatsSectionProps {
	chats: ChatDTO[];
	selectedChatId: string | null;
	projectSelected: boolean;
	loading: boolean;
	creating: boolean;
	onCreateChat: (title: string) => void;
	onSelectChat: (chatId: string) => void;
}

export const ChatsSection = ({
	chats,
	selectedChatId,
	projectSelected,
	loading,
	creating,
	onCreateChat,
	onSelectChat,
}: ChatsSectionProps): JSX.Element => {
	const [title, setTitle] = useState("");

	const handleCreateChat = (event: FormEvent<HTMLFormElement>) => {
		event.preventDefault();

		if (!projectSelected || creating) {
			return;
		}

		onCreateChat(title.trim().length > 0 ? title.trim() : "New chat");
		setTitle("");
	};

	return (
		<section className="panel muted">
			<header className="panel-header">
				<div>
					<h2>Chats</h2>
					<span className="panel-subtitle">Chat list</span>
				</div>
			</header>

			<form className="project-form" onSubmit={handleCreateChat}>
				<label className="label" htmlFor="chat-title">
					Chat title (optional)
				</label>
				<input
					aria-label="Chat title"
					id="chat-title"
					onChange={(event) => {
						setTitle(event.target.value);
					}}
					placeholder="Chat title"
					value={title}
				/>
				<button disabled={!projectSelected || creating} type="submit">
					{creating ? "Creating chat..." : "Create chat"}
				</button>
			</form>

			{loading ? (
				<p className="small-muted">Loading chat list...</p>
			) : (
				<ul className="chat-list">
					{chats.length === 0 ? (
						<li className="empty-state">No chats found.</li>
					) : (
						chats.map((chat) => (
							<li
								className={`item ${selectedChatId === chat.id ? "active" : ""}`}
								key={chat.id}
							>
								<button
									className="item-main"
									aria-label={`Select ${chat.title} chat`}
									onClick={() => {
										onSelectChat(chat.id);
									}}
									type="button"
								>
									<div className="chat-title">{chat.title}</div>
									<div className="chat-meta small-muted">
										{chat.provider} · Status {chat.status}
									</div>
								</button>
								<span className="chat-badge">
									+{chat.diffAdded} / -{chat.diffRemoved}
								</span>
							</li>
						))
					)}
				</ul>
			)}
		</section>
	);
};
