import { useCallback, useEffect, useMemo, useRef } from "react";

import { RemoteCodeApi, RemoteCodeApiError } from "../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../shared/realtime/remotecode-ws";
import { useWorkspaceStore } from "../features/workspace/model/useWorkspaceStore";
import { ChatsSection } from "../features/chats/ui/ChatsSection";
import { ConversationPanel } from "../features/conversation/ui/ConversationPanel";
import { MessageComposer } from "../features/composer/ui/MessageComposer";
import { ProjectsSection } from "../features/projects/ui/ProjectsSection";

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
		dispatch,
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

	const connectionMessage = useMemo(() => {
		switch (state.connectionState) {
			case "connected":
				return "Connected";
			case "connecting":
				return "Connecting…";
			case "reconnecting":
				return "Reconnecting…";
			case "disconnected":
				return "Disconnected";
			default:
				return "Idle";
		}
	}, [state.connectionState]);

	return (
		<div className="app-shell">
			<header className="main-header">
				<h1>Remotecode IDE</h1>
				<p className="small-muted">{connectionMessage}</p>
			</header>
			<div className="toolbar">
				<button onClick={() => void loadProjects()} type="button">
					Reload projects
				</button>
				{state.errors.length > 0 ? (
					<button onClick={clearAllErrors} type="button">
						Clear errors
					</button>
				) : null}
			</div>
			<div className="workspace-layout">
				<aside className="sidebar">
					<ProjectsSection
						creating={state.isCreatingProject}
						loading={state.projectsLoading}
						onCreateProject={handleCreateProject}
						onSelectProject={handleSelectProject}
						onToggleFavorite={handleToggleFavorite}
						projects={state.projects}
						selectedProjectId={state.selectedProjectId}
					/>
					<ChatsSection
						chats={state.chats}
						creating={state.isCreatingChat}
						loading={state.chatsLoading}
						onCreateChat={handleCreateChat}
						onSelectChat={handleSelectChat}
						projectSelected={Boolean(selectedProject)}
						selectedChatId={state.selectedChatId}
					/>
				</aside>
				<main className="content-panel">
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
									×
								</button>
								<strong>{error.code}</strong> · {error.message}
							</div>
							))}
						</div>
					) : null}
					<ConversationPanel
						chat={selectedChat}
						loading={state.messagesLoading}
						hasRestError={state.errors.some((error) => error.source === "rest")}
						messages={state.messages}
						streamingText={streamingText}
					/>
					<MessageComposer
						chatStatus={selectedChat?.status ?? null}
						disabled={!state.selectedChatId}
						onSend={handleSendMessage}
						sending={state.isSendingMessage}
					/>
				</main>
			</div>
		</div>
	);
};

export default App;
