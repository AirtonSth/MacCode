import { useCallback, useEffect, useMemo, useRef } from "react";

import { RemoteCodeApi, RemoteCodeApiError } from "../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../shared/realtime/remotecode-ws";
import { useWorkspaceStore } from "../features/workspace/model/useWorkspaceStore";
import { ConversationPanel } from "../features/conversation/ui/ConversationPanel";
import { MessageComposer } from "../features/composer/ui/MessageComposer";

const formatRelativeTime = (dateString: string): string => {
	const timestamp = new Date(dateString).getTime();
	if (Number.isNaN(timestamp)) {
		return "now";
	}

	const difference = Math.max(0, Date.now() - timestamp);
	if (difference < 60_000) {
		return "now";
	}

	const minutes = Math.floor(difference / 60_000);
	if (minutes < 60) {
		return `${minutes}m`;
	}

	const hours = Math.floor(minutes / 60);
	if (hours < 24) {
		return `${hours}h`;
	}

	const days = Math.floor(hours / 24);
	return `${days}d`;
};

const formatProjectMeta = (absolutePath: string): string => {
	const cleanPath = absolutePath.trim().replace(/\\/g, "/").replace(/\/+$/u, "");
	const segments = cleanPath.split("/").filter(Boolean);
	if (segments.length < 2) {
		return "local";
	}

	return segments[segments.length - 2];
};

const SUGGESTION_CARDS = [
	"Build a classic Snake game in this repo.",
	"Create a one-page PDF that summarizes this app.",
	"Create a plan to improve the backend architecture.",
];

const App = (): JSX.Element => {
	const { dispatch, state } = useWorkspaceStore();
	const wsRef = useRef<ReturnType<(typeof RemoteCodeRealtime)["createClient"]> | null>(null);
	const selectedChatIdRef = useRef<string | null>(null);

	const baseUrl = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:3001").trim();
	}, []);

	const token = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "local-dev-token").trim();
	}, []);

	const api = useMemo(() => RemoteCodeApi.createClient({ baseUrl, token }), [baseUrl, token]);

	const selectedProject = useMemo(
		() => state.projects.find((project) => project.id === state.selectedProjectId) ?? null,
		[state.projects, state.selectedProjectId],
	);

	const selectedChat = useMemo(
		() => state.chats.find((chat) => chat.id === state.selectedChatId) ?? null,
		[state.chats, state.selectedChatId],
	);

	const streamingText = selectedChatIdRef.current
		? state.streamingByChat[selectedChatIdRef.current] ?? ""
		: "";

	useEffect(() => {
		selectedChatIdRef.current = state.selectedChatId;
	}, [state.selectedChatId]);

	const addError = useCallback(
		(message: string, source: "rest" | "ws", code = "unknown") => {
			dispatch({
				type: "ADD_ERROR",
				payload: { source, code, message },
			});
		},
		[dispatch],
	);

	const formatApiErrorCode = useCallback((error: unknown) => {
		return error instanceof RemoteCodeApiError ? `HTTP_${error.status}` : "NETWORK";
	}, []);

	const formatApiErrorMessage = useCallback((error: unknown, fallback: string) => {
		return error instanceof Error ? error.message : fallback;
	}, []);

	const loadMessagesForChat = useCallback(
		async (chatId: string | null) => {
			if (!chatId) {
				dispatch({ type: "SET_MESSAGES", payload: [] });
				dispatch({ type: "SET_MESSAGES_LOADING", payload: false });
				return;
			}

			dispatch({ type: "SET_MESSAGES_LOADING", payload: true });
			try {
				const messages = await api.listMessages(chatId);
				dispatch({ type: "SET_MESSAGES", payload: messages });
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to fetch messages from chat"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				dispatch({ type: "SET_MESSAGES_LOADING", payload: false });
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const loadChatsForProject = useCallback(
		async (projectId: string | null) => {
			if (!projectId) {
				dispatch({ type: "SET_CHATS", payload: [] });
				dispatch({ type: "SET_SELECTED_CHAT", payload: null });
				dispatch({ type: "SET_CHATS_LOADING", payload: false });
				return;
			}

			dispatch({ type: "SET_SELECTED_CHAT", payload: null });
			dispatch({ type: "SET_CHATS_LOADING", payload: true });
			try {
				const chats = await api.listChats(projectId);
				dispatch({ type: "SET_CHATS", payload: chats });
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to load chats for project"),
					"rest",
					formatApiErrorCode(error),
				);
				dispatch({ type: "SET_CHATS", payload: [] });
			} finally {
				dispatch({ type: "SET_CHATS_LOADING", payload: false });
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const loadProjects = useCallback(async () => {
		dispatch({ type: "SET_PROJECTS_LOADING", payload: true });
		try {
			const projects = await api.listProjects();
			dispatch({ type: "SET_PROJECTS", payload: projects });
			dispatch({
				type: "SET_SELECTED_PROJECT",
				payload: projects[0]?.id ?? null,
			});
		} catch (error) {
			addError(
				formatApiErrorMessage(error, "Unable to load projects"),
				"rest",
				formatApiErrorCode(error),
			);
		} finally {
			dispatch({ type: "SET_PROJECTS_LOADING", payload: false });
		}
	}, [addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage]);

	const handleWsEvent = useCallback(
		async (event: ServerWsEvent) => {
			switch (event.event) {
				case "assistant_delta":
					dispatch({
						type: "APPEND_STREAMING",
						payload: {
							chatId: event.data.chatId,
							delta: event.data.delta,
						},
					});
					if (selectedChatIdRef.current === event.data.chatId) {
						dispatch({
							type: "SET_SENDING_MESSAGE",
							payload: false,
						});
					}
					break;
				case "assistant_done":
					dispatch({
						type: "CLEAR_STREAMING",
						payload: { chatId: event.data.chatId },
					});
					if (selectedChatIdRef.current === event.data.chatId) {
						await loadMessagesForChat(event.data.chatId);
					}
					dispatch({
						type: "SET_SENDING_MESSAGE",
						payload: false,
					});
					break;
				case "chat_updated":
					dispatch({
						type: "UPDATE_CHAT",
						payload: {
							id: event.data.chatId,
							diffAdded: event.data.diffAdded,
							diffRemoved: event.data.diffRemoved,
							status: event.data.status,
							updatedAt: event.data.updatedAt,
						},
					});
					break;
				case "error":
					addError(event.data.message, "ws", event.data.code);
					if (event.data.chatId) {
						dispatch({
							type: "CLEAR_STREAMING",
							payload: { chatId: event.data.chatId },
						});
						if (selectedChatIdRef.current === event.data.chatId) {
							dispatch({
								type: "SET_SENDING_MESSAGE",
								payload: false,
							});
						}
					}
					break;
			}
		},
		[addError, dispatch, loadMessagesForChat],
	);

	const handleWsState = useCallback(
		(connectionState: ConnectionState) => {
			dispatch({ type: "SET_CONNECTION_STATE", payload: connectionState });
			if (connectionState === "connected" && selectedChatIdRef.current) {
				wsRef.current?.sendJoinChat(selectedChatIdRef.current);
				void loadMessagesForChat(selectedChatIdRef.current);
			}
		},
		[dispatch, loadMessagesForChat],
	);

	const handleBootstrap = useCallback(() => {
		dispatch({
			type: "BOOTSTRAP_CONFIG",
			payload: { baseUrl, token },
		});
		return loadProjects();
	}, [baseUrl, dispatch, loadProjects, token]);

	useEffect(() => {
		void handleBootstrap();
	}, [handleBootstrap]);

	useEffect(() => {
		void loadChatsForProject(state.selectedProjectId);
	}, [loadChatsForProject, state.selectedProjectId]);

	useEffect(() => {
		void loadMessagesForChat(state.selectedChatId);
	}, [loadMessagesForChat, state.selectedChatId]);

	useEffect(() => {
		const client = RemoteCodeRealtime.createClient({
			baseUrl,
			onConnectionStateChange: handleWsState,
			onEvent: (event) => {
				handleWsEvent(event);
			},
			token,
		});

		wsRef.current = client;
		client.connect();

		return () => {
			client.disconnect();
		};
	}, [baseUrl, handleWsEvent, handleWsState, token]);

	useEffect(() => {
		if (state.connectionState === "connected" && state.selectedChatId) {
			wsRef.current?.sendJoinChat(state.selectedChatId);
		}
	}, [state.connectionState, state.selectedChatId]);

	const handleCreateProject = useCallback(
		async (input: { name?: string; path: string }) => {
			dispatch({ type: "SET_CREATING_PROJECT", payload: true });
			try {
				const project = await api.createProject(input);
				dispatch({ type: "UPSERT_PROJECT", payload: project });
				if (!state.selectedProjectId) {
					dispatch({ type: "SET_SELECTED_PROJECT", payload: project.id });
				}
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to create project"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				dispatch({ type: "SET_CREATING_PROJECT", payload: false });
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, state.selectedProjectId],
	);

	const handleToggleFavorite = useCallback(
		async (projectId: string, isFavorite: boolean) => {
			dispatch({ type: "TOGGLE_FAVORITE", payload: { id: projectId, isFavorite } });
			try {
				const project = await api.toggleFavorite(projectId, isFavorite);
				dispatch({ type: "UPSERT_PROJECT", payload: project });
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to update project"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const handleCreateChat = useCallback(
		async (title: string) => {
			if (!state.selectedProjectId) {
				addError("Select a project before creating a chat", "rest", "missing_project");
				return;
			}

			dispatch({ type: "SET_CREATING_CHAT", payload: true });
			try {
				const chat = await api.createChat(state.selectedProjectId, title);
				dispatch({ type: "UPSERT_CHAT", payload: chat });
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to create chat"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				dispatch({ type: "SET_CREATING_CHAT", payload: false });
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, state.selectedProjectId],
	);

	const handleSendMessage = useCallback(
		async (text: string) => {
			if (!state.selectedChatId) {
				return;
			}

			const chatId = state.selectedChatId;

			dispatch({
				type: "SET_SENDING_MESSAGE",
				payload: true,
			});
			dispatch({
				type: "APPEND_MESSAGE",
				payload: {
					chatId,
					content: text,
					createdAt: new Date().toISOString(),
					id: crypto.randomUUID(),
					role: "user",
				},
			});
			dispatch({
				type: "CLEAR_STREAMING",
				payload: { chatId },
			});

			if (!wsRef.current) {
				addError("WebSocket client is not ready", "ws", "not_ready");
				dispatch({
					type: "SET_SENDING_MESSAGE",
					payload: false,
				});
				return;
			}

			wsRef.current.sendUserMessage(chatId, text);
		},
		[addError, dispatch, state.selectedChatId],
	);

	const handleSelectProject = useCallback(
		(projectId: string) => {
			if (projectId === state.selectedProjectId) {
				return;
			}

			dispatch({ type: "SET_SELECTED_CHAT", payload: null });
			dispatch({ type: "SET_SELECTED_PROJECT", payload: projectId });
		},
		[dispatch, state.selectedProjectId],
	);

	const handleSelectChat = useCallback(
		(chatId: string) => {
			if (chatId === state.selectedChatId) {
				return;
			}

			dispatch({ type: "SET_SELECTED_CHAT", payload: chatId });
		},
		[dispatch, state.selectedChatId],
	);

	const clearAllErrors = useCallback(() => {
		dispatch({ type: "CLEAR_ERRORS" });
	}, [dispatch]);

	const handleOpenProject = useCallback(() => {
		const projectPath = window.prompt("Enter the absolute project path");
		if (projectPath === null) {
			return;
		}

		const trimmedPath = projectPath.trim();
		if (!trimmedPath) {
			return;
		}

		const nameInput = window.prompt("Project name (optional)") ?? "";
		void handleCreateProject({
			name: nameInput.trim().length > 0 ? nameInput.trim() : undefined,
			path: trimmedPath,
		});
	}, [handleCreateProject]);

	const connectionMessage = useMemo(() => {
		switch (state.connectionState) {
			case "connected":
				return "Connected";
			case "connecting":
				return "Connecting...";
			case "reconnecting":
				return "Reconnecting...";
			case "disconnected":
				return "Disconnected";
			default:
				return "Idle";
		}
	}, [state.connectionState]);

	return (
		<div className="codex-desktop">
			<div className="codex-window">
				<aside className="codex-sidebar">
					<nav className="sidebar-nav" aria-label="Workspace navigation">
						<button
							className="nav-entry active"
							disabled={!selectedProject || state.isCreatingChat}
							onClick={() => {
								void handleCreateChat("New thread");
							}}
							type="button"
						>
							New thread
						</button>
						<button className="nav-entry" type="button">
							Automations
						</button>
						<button className="nav-entry" type="button">
							Skills
						</button>
					</nav>

					<div className="sidebar-caption">Threads</div>
					<div className="thread-scroller">
						{state.projectsLoading ? (
							<p className="small-muted">Loading workspaces...</p>
						) : (
							state.projects.map((project) => {
								const isSelectedProject = project.id === state.selectedProjectId;
								return (
									<section
										className={`project-group ${isSelectedProject ? "selected" : ""}`}
										key={project.id}
									>
										<div className="project-row">
											<button
												aria-label={`Select ${project.name}`}
												className="project-select"
												onClick={() => {
													handleSelectProject(project.id);
												}}
												type="button"
											>
												<span className="folder-icon" aria-hidden="true">
													<svg viewBox="0 0 24 24">
														<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v1H3V7z" />
														<path d="M3 10h18v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7z" />
													</svg>
												</span>
												<span className="project-meta">
													<span className="project-title">{project.name}</span>
													<span className="project-subtitle">
														{formatProjectMeta(project.path)}
													</span>
												</span>
											</button>
											<button
												aria-label={
													project.isFavorite
														? "Remove from favorites"
														: "Add to favorites"
												}
												className={`favorite-toggle ${project.isFavorite ? "active" : ""}`}
												onClick={() => {
													void handleToggleFavorite(project.id, !project.isFavorite);
												}}
												type="button"
											>
												*
											</button>
										</div>

										{isSelectedProject ? (
											<ul className="thread-list">
												{state.chatsLoading ? (
													<li className="thread-empty">Loading threads...</li>
												) : state.chats.length === 0 ? (
													<li className="thread-empty">No threads yet.</li>
												) : (
													state.chats.map((chat) => (
														<li key={chat.id}>
															<button
																aria-label={`Open ${chat.title}`}
																className={`thread-item ${state.selectedChatId === chat.id ? "active" : ""}`}
																onClick={() => {
																	handleSelectChat(chat.id);
																}}
																type="button"
															>
																<span className="thread-title">{chat.title}</span>
																<span className="thread-time">
																	{formatRelativeTime(chat.updatedAt)}
																</span>
															</button>
														</li>
													))
												)}
											</ul>
										) : null}
									</section>
								);
							})
						)}
					</div>

					<footer className="sidebar-footer">
						<button className="sidebar-settings" type="button">
							Settings
						</button>
					</footer>
				</aside>

				<main className="codex-main">
					<header className="codex-main-header">
						<h1>{selectedChat ? selectedChat.title : "New thread"}</h1>
						<div className="header-actions">
							<button className="header-pill primary" onClick={handleOpenProject} type="button">
								Open
							</button>
							<button
								className="header-pill"
								onClick={() => {
									void loadProjects();
								}}
								type="button"
							>
								Reload
							</button>
							{state.errors.length > 0 ? (
								<button className="header-icon danger" onClick={clearAllErrors} type="button">
									!
								</button>
							) : null}
						</div>
					</header>

					<section className="codex-main-body">
						{state.errors.length > 0 ? (
							<div className="error-stack">
								{state.errors.map((error) => (
									<div className="error-item" key={error.id}>
										<button
											aria-label={`Dismiss ${error.message}`}
											onClick={() => {
												dispatch({ type: "REMOVE_ERROR", payload: error.id });
											}}
											type="button"
										>
											x
										</button>
										<strong>{error.code}</strong>
										<span>{error.message}</span>
									</div>
								))}
							</div>
						) : null}

						<div className="stage-content">
							{state.selectedChatId ? (
								<ConversationPanel
									chat={selectedChat}
									loading={state.messagesLoading}
									hasRestError={state.errors.some((error) => error.source === "rest")}
									messages={state.messages}
									streamingText={streamingText}
								/>
							) : (
								<div className="codex-empty-state">
									<div className="codex-logo" aria-hidden="true">
										<svg viewBox="0 0 24 24">
											<path d="M12 3.5a4.8 4.8 0 0 1 4.74 4.13 4.7 4.7 0 0 1 3.76 4.57 4.7 4.7 0 0 1-4.69 4.69H15v2.1H9v-2.1H8.2a4.7 4.7 0 0 1-.56-9.37A4.8 4.8 0 0 1 12 3.5z" />
										</svg>
									</div>
									<h2>Let&apos;s build</h2>
									<p>{selectedProject?.name ?? "remotecode.io"}</p>
								</div>
							)}
						</div>

						<div className="composer-dock">
							{!state.selectedChatId ? (
								<div className="suggestions">
									{SUGGESTION_CARDS.map((card) => (
										<button className="suggestion-card" key={card} type="button">
											{card}
										</button>
									))}
								</div>
							) : null}
							<MessageComposer
								chatStatus={selectedChat?.status ?? null}
								disabled={!state.selectedChatId}
								onSend={handleSendMessage}
								sending={state.isSendingMessage}
							/>
							<div className="composer-status-row">
								<span>Local</span>
								<span>{connectionMessage}</span>
								<span>{selectedProject?.name ?? "No workspace"}</span>
							</div>
						</div>
					</section>
				</main>
			</div>
		</div>
	);
};

export default App;
