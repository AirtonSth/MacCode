import { useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AppState, type AppStateStatus } from "react-native";

import { useChatsQuery } from "../api/use-chats-query";
import { useCreateChatMutation } from "../api/use-create-chat-mutation";
import { useDeleteChatMutation } from "../api/use-delete-chat-mutation";
import {
	appendMessageToMessagePages,
	MESSAGE_PAGE_SIZE,
	replaceNewestMessagePage,
	useMessagesQuery,
} from "../api/use-messages-query";
import { useUpdateWorkspaceSelectionMutation } from "../../settings/api/use-update-workspace-selection-mutation";
import { useWorkspaceSelectionQuery } from "../../settings/api/use-workspace-selection-query";
import { useProjectsQuery } from "../../threads/api/use-projects-query";
import { useToggleFavoriteMutation } from "../../threads/api/use-toggle-favorite-mutation";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { queryKeys } from "../../../shared/api/query-keys";
import { createRealtimeClient, type ConnectionState } from "../../../shared/api/ws-client";
import type {
	AssistantStreamItemState,
	ChatDTO,
	ChatStreamEventDTO,
	MessageDTO,
	MessagePageDTO,
	ProjectDTO,
	ServerWsEvent,
	WorkspaceSelectionDTO,
} from "../../../shared/api/types";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import {
	ensureLocalNotificationPermission,
	sendThreadCompletionNotification,
} from "../../../shared/notifications/local-notifications";
import {
	applyAssistantEventToTurn,
	cloneTurn,
	setStreamItemExpanded as updateStreamItemExpanded,
	setStreamItemState as updateStreamItemState,
	type StreamTurnState,
} from "./stream-turn-state";

type AssistantEventPayload = Extract<ServerWsEvent, { event: "assistant_event" }>["data"]["event"];

const upsertTurnHistory = (turns: StreamTurnState[] | undefined, turn: StreamTurnState): StreamTurnState[] => {
	const current = turns ?? [];
	const index = current.findIndex((item) => item.turnId === turn.turnId);
	if (index === -1) {
		return [...current, turn];
	}

	const next = Array.from(current);
	next[index] = turn;
	return next;
};

const collapseTurnItems = (turn: StreamTurnState): StreamTurnState => {
	const nextTurn = cloneTurn(turn);
	for (const itemId of nextTurn.itemOrder) {
		const item = nextTurn.itemsById[itemId];
		if (!item) {
			continue;
		}
		nextTurn.itemsById[itemId] = {
			...item,
			state: item.state === "failed" || item.state === "cancelled" ? item.state : "collapsed",
			isExpanded: false,
			expandedByUser: false,
		};
	}

	return nextTurn;
};

const applyAssistantEventToHistory = (
	turns: StreamTurnState[] | undefined,
	event: AssistantEventPayload,
): StreamTurnState[] => {
	const current = turns ?? [];
	const existingTurn = current.find((item) => item.turnId === event.turnId) ?? null;
	let nextTurn = applyAssistantEventToTurn(existingTurn, event);
	if (event.type === "item_completed") {
		const completedItem = nextTurn.itemsById[event.itemId];
		const isResponseCompletedSummary =
			typeof event.summary === "string" && event.summary.toLowerCase().includes("response completed");
		if (completedItem?.type === "assistant_message" || isResponseCompletedSummary) {
			nextTurn = collapseTurnItems(nextTurn);
		}
	}
	if (event.type === "turn_completed") {
		nextTurn = collapseTurnItems(nextTurn);
	}
	return upsertTurnHistory(current, nextTurn);
};

const replayAssistantEventsIntoTurns = (events: ChatStreamEventDTO[]): StreamTurnState[] => {
	let turns: StreamTurnState[] = [];
	for (const entry of events) {
		turns = applyAssistantEventToHistory(turns, entry.event);
	}
	return turns;
};

const upsertUpdatedChat = (chats: ChatDTO[], update: ServerWsEvent & { event: "chat_updated" }): ChatDTO[] => {
	return chats.map((chat) =>
		chat.id === update.data.chatId
			? {
				...chat,
				diffAdded: update.data.diffAdded,
				diffRemoved: update.data.diffRemoved,
				status: update.data.status,
				updatedAt: update.data.updatedAt,
			}
			: chat,
	);
};

const isPlaceholderThreadTitle = (title: string): boolean => {
	const normalized = title.trim().toLowerCase();
	return normalized === "new thread" || normalized === "new chat";
};

const toRequestId = (): string =>
	`req-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`;

const permissionModes = ["plan", "default", "full"] as const;
const reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"] as const;

const normalizePermissionMode = (value: string | null | undefined): string => {
	return typeof value === "string" && (permissionModes as readonly string[]).includes(value)
		? value
		: "default";
};

const normalizeSelectedModel = (value: string | null | undefined): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
};

const normalizeReasoningEffort = (value: string | null | undefined): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	if (trimmed.length === 0) {
		return null;
	}

	return (reasoningEfforts as readonly string[]).includes(trimmed) ? trimmed : null;
};

const normalizeSelection = (
	selection: WorkspaceSelectionDTO,
): WorkspaceSelectionDTO => {
	const selectedProjectId = selection.selectedProjectId;
	const selectedChatId = selectedProjectId && typeof selection.selectedChatId === "string" ? selection.selectedChatId : null;
	return {
		selectedProjectId,
		selectedChatId,
		permissionMode: normalizePermissionMode(selection.permissionMode),
		selectedModel: normalizeSelectedModel(selection.selectedModel),
		selectedReasoningEffort: normalizeReasoningEffort(selection.selectedReasoningEffort),
	};
};

const hasSameSelection = (
	left: WorkspaceSelectionDTO,
	right: WorkspaceSelectionDTO,
): boolean =>
	left.selectedProjectId === right.selectedProjectId &&
	left.selectedChatId === right.selectedChatId &&
	left.permissionMode === right.permissionMode &&
	left.selectedModel === right.selectedModel &&
	left.selectedReasoningEffort === right.selectedReasoningEffort;

let inMemorySelectedProjectId: string | null = null;
let inMemorySelectedChatId: string | null = null;

export const useWorkspaceShell = () => {
	const queryClient = useQueryClient();
	const { config } = useApiConfig();
	const createChatMutation = useCreateChatMutation();
	const updateSelectionMutation = useUpdateWorkspaceSelectionMutation();
	const [lastError, setLastError] = useState<string | null>(null);
	const [sendingByChat, setSendingByChat] = useState<Record<string, boolean>>({});
	const [connectionState, setConnectionState] = useState<ConnectionState>("idle");
	const [selectedProjectId, setSelectedProjectId] = useState<string | null>(inMemorySelectedProjectId);
	const [selectedChatId, setSelectedChatId] = useState<string | null>(inMemorySelectedChatId);
	const [streamingTextByChat, setStreamingTextByChat] = useState<Record<string, string>>({});
	const [streamHistoryByChat, setStreamHistoryByChat] = useState<Record<string, StreamTurnState[]>>({});
	const [permissionMode, setPermissionMode] = useState<string>("default");
	const [selectedModel, setSelectedModel] = useState<string | null>(null);
	const [selectedReasoningEffort, setSelectedReasoningEffort] = useState<string | null>(null);
	const realtimeRef = useRef<ReturnType<typeof createRealtimeClient> | null>(null);
	const lastWorkspaceSeqRef = useRef<number>(0);
	const selectedProjectIdRef = useRef<string | null>(selectedProjectId);
	const selectedChatIdRef = useRef<string | null>(selectedChatId);
	const pendingSendChatIdsRef = useRef<Set<string>>(new Set());
	const pendingCompletionNotificationChatIdsRef = useRef<Set<string>>(new Set());
	const lastAssistantEventIdByChatRef = useRef<Record<string, number>>({});
	const appStateRef = useRef<AppStateStatus>(AppState.currentState);
	const clientIdRef = useRef<string>(`mobile-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`);
	const hasBootstrappedSelectionRef = useRef<boolean>(false);
	const pendingSelectionRef = useRef<WorkspaceSelectionDTO | null>(null);
	const client = useRemoteCodeClient();
	const projectsQuery = useProjectsQuery();
	const chatsQuery = useChatsQuery(selectedProjectId);
	const messagesQuery = useMessagesQuery(selectedChatId);
	const selectionQuery = useWorkspaceSelectionQuery();
	const toggleFavoriteMutation = useToggleFavoriteMutation();
	const deleteChatMutation = useDeleteChatMutation(selectedProjectId);
	const modelsQuery = useQuery({
		queryKey: ["codex-models"],
		queryFn: async () => await client.listCodexModels(),
		staleTime: 5 * 60_000,
	});

	useEffect(() => {
		const models = modelsQuery.data?.models ?? [];
		if (models.length === 0) {
			return;
		}

		const defaultModel = models.find((item) => item.isDefault)?.model ?? models[0]?.model ?? null;
		if (defaultModel && !selectedModel) {
			setSelectedModel(defaultModel);
		}
	}, [modelsQuery.data?.models, selectedModel]);

	const streamTurnQuery = useQuery<StreamTurnState | null>({
		gcTime: Number.POSITIVE_INFINITY,
		initialData: null,
		queryFn: async () => null,
		queryKey: queryKeys.streamTurn(selectedChatId),
		staleTime: Number.POSITIVE_INFINITY,
	});

	useEffect(() => {
		if (!selectionQuery.data) {
			return;
		}

		const normalizedSelection = normalizeSelection(selectionQuery.data);
		const pendingSelection = pendingSelectionRef.current;
		if (pendingSelection && !hasSameSelection(pendingSelection, normalizedSelection)) {
			return;
		}

		pendingSelectionRef.current = null;
		inMemorySelectedProjectId = normalizedSelection.selectedProjectId;
		inMemorySelectedChatId = normalizedSelection.selectedChatId;
		setSelectedProjectId(normalizedSelection.selectedProjectId);
		setSelectedChatId(normalizedSelection.selectedChatId);
		setPermissionMode(normalizedSelection.permissionMode);
		setSelectedModel(normalizedSelection.selectedModel);
		setSelectedReasoningEffort(normalizedSelection.selectedReasoningEffort);
		hasBootstrappedSelectionRef.current = true;
	}, [selectionQuery.data]);

	useEffect(() => {
		selectedProjectIdRef.current = selectedProjectId;
	}, [selectedProjectId]);

	useEffect(() => {
		selectedChatIdRef.current = selectedChatId;
	}, [selectedChatId]);

	const notifyMessageCompletion = useCallback(
		(chatId: string, outcome: "completed" | "error" | "failed") => {
			if (!pendingCompletionNotificationChatIdsRef.current.has(chatId)) {
				return;
			}

			pendingCompletionNotificationChatIdsRef.current.delete(chatId);
			const activeProjectId = selectedProjectIdRef.current;
			const chats = queryClient.getQueryData<ChatDTO[]>(queryKeys.chats(activeProjectId)) ?? [];
			const chatTitle = chats.find((chat) => chat.id === chatId)?.title;

			void (async () => {
				try {
					await sendThreadCompletionNotification({
						chatId,
						chatTitle: chatTitle?.trim().length ? chatTitle : undefined,
						outcome,
					});
				} catch {
					// Ignore local notification failures.
				}
			})();
		},
		[queryClient],
	);

	const syncMissedAssistantEventsForChat = useCallback(
		async (chatId: string) => {
			const collectEvents = async (
				afterId: number,
				accumulator: ChatStreamEventDTO[],
			): Promise<ChatStreamEventDTO[]> => {
				const page = await client.listChatStreamEvents(chatId, {
					afterId,
					limit: 500,
				});
				const nextEvents = [...accumulator, ...page.events];

				if (!page.hasMore || page.nextAfterId === null) {
					return nextEvents;
				}

				return await collectEvents(page.nextAfterId, nextEvents);
			};

			const lastKnownEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
			try {
				const events = await collectEvents(lastKnownEventId, []);
				if (events.length === 0) {
					return;
				}

				setStreamHistoryByChat((current) => {
					let nextTurns = current[chatId] ?? [];
					let appliedAnyEvent = false;

					for (const entry of events) {
						const lastAppliedEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
						if (entry.id <= lastAppliedEventId) {
							continue;
						}

						nextTurns = applyAssistantEventToHistory(nextTurns, entry.event);
						lastAssistantEventIdByChatRef.current[chatId] = entry.id;
						appliedAnyEvent = true;
					}

					if (!appliedAnyEvent) {
						return current;
					}

					queryClient.setQueryData<StreamTurnState | null>(
						queryKeys.streamTurn(chatId),
						nextTurns.at(-1) ?? null,
					);
					return {
						...current,
						[chatId]: nextTurns,
					};
				});
			} catch {
				void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
			}
		},
		[client, queryClient],
	);

	const handleServerEvent = useCallback(
		(event: ServerWsEvent) => {
			const clearSendingForChat = (chatId: string) => {
				if (!pendingSendChatIdsRef.current.has(chatId)) {
					return;
				}

				pendingSendChatIdsRef.current.delete(chatId);
				setSendingByChat((current) => ({
					...current,
					[chatId]: false,
				}));
			};

			if (event.event === "assistant_delta") {
				setStreamingTextByChat((current) => ({
					...current,
					[event.data.chatId]: `${current[event.data.chatId] ?? ""}${event.data.delta}`,
				}));
				clearSendingForChat(event.data.chatId);
				return;
			}

			if (event.event === "assistant_snapshot") {
				setStreamingTextByChat((current) => ({
					...current,
					[event.data.chatId]: event.data.partialText,
				}));
				return;
			}

			if (event.event === "assistant_event") {
				const incomingEventId = event.data.eventId;
				const chatId = event.data.chatId;
				const lastAppliedEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
				if (typeof incomingEventId === "number" && incomingEventId <= lastAppliedEventId) {
					return;
				}
				if (typeof incomingEventId === "number") {
					lastAssistantEventIdByChatRef.current[chatId] = incomingEventId;
				}

				setStreamHistoryByChat((current) => {
					const nextHistory = applyAssistantEventToHistory(current[chatId], event.data.event);
					queryClient.setQueryData<StreamTurnState | null>(
						queryKeys.streamTurn(chatId),
						nextHistory.at(-1) ?? null,
					);
					return {
						...current,
						[chatId]: nextHistory,
					};
				});
				clearSendingForChat(event.data.chatId);
				return;
			}

			if (event.event === "assistant_done") {
				const chatId = event.data.chatId;
				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(chatId),
					(current) => (current ? collapseTurnItems(current) : current),
				);
				setStreamHistoryByChat((current) => {
					const turns = current[chatId] ?? [];
					if (turns.length === 0) {
						return current;
					}

					const nextTurns = turns.map((turn, index) => (
						index === turns.length - 1 ? collapseTurnItems(turn) : turn
					));
					queryClient.setQueryData<StreamTurnState | null>(
						queryKeys.streamTurn(chatId),
						nextTurns.at(-1) ?? null,
					);
					return {
						...current,
						[chatId]: nextTurns,
					};
				});

				void (async () => {
					const maxAttempts = 5;
					const retryDelayMs = 250;
					const trySyncMessages = async (attempt: number): Promise<void> => {
						try {
							const latestPage = await client.listMessagesPage(chatId, {
								limit: MESSAGE_PAGE_SIZE,
							});
							if (latestPage.messages.at(-1)?.role === "assistant") {
								const currentPages = queryClient.getQueryData<InfiniteData<MessagePageDTO>>(queryKeys.messages(chatId));
								if ((currentPages?.pages.length ?? 0) > 1) {
									void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
								} else {
									queryClient.setQueryData<InfiniteData<MessagePageDTO>>(
										queryKeys.messages(chatId),
										(current) => replaceNewestMessagePage(current, latestPage),
									);
								}
								return;
							}
						} catch {
							// Keep retrying until maxAttempts.
						}

						if (attempt >= maxAttempts) {
							void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
							return;
						}

						setTimeout(() => {
							void trySyncMessages(attempt + 1);
						}, retryDelayMs);
					};

					await trySyncMessages(1);
				})();
				setStreamingTextByChat((current) => ({
					...current,
					[chatId]: "",
				}));
				clearSendingForChat(chatId);
				notifyMessageCompletion(chatId, "completed");
				return;
			}

			if (event.event === "chat_updated") {
				const activeProjectId = selectedProjectIdRef.current;
				queryClient.setQueryData<ChatDTO[]>(
					queryKeys.chats(activeProjectId),
					(current) => upsertUpdatedChat(current ?? [], event),
				);
				if (event.data.status !== "running") {
					clearSendingForChat(event.data.chatId);
				}
				if (event.data.status === "completed" || event.data.status === "failed") {
					notifyMessageCompletion(event.data.chatId, event.data.status);
				}
				return;
			}

			if (event.event === "error") {
				setLastError(event.data.message);
				if (event.data.chatId) {
					const chatId = event.data.chatId;
					queryClient.setQueryData(queryKeys.streamTurn(chatId), null);
					setStreamingTextByChat((current) => ({
						...current,
						[chatId]: "",
					}));
					clearSendingForChat(chatId);
					notifyMessageCompletion(chatId, "error");
				}
				return;
			}

			if (event.event === "workspace_event") {
				lastWorkspaceSeqRef.current = Math.max(lastWorkspaceSeqRef.current, event.data.seq);
				const activeProjectId = selectedProjectIdRef.current;
				const activeChatId = selectedChatIdRef.current;

				switch (event.data.type) {
					case "chat_created":
					case "chat_deleted":
					case "chat_updated": {
						void queryClient.invalidateQueries({ queryKey: queryKeys.chats(activeProjectId) });
						break;
					}
					case "git_updated": {
						void queryClient.invalidateQueries({ queryKey: queryKeys.projectGitStatusRoot });
						void queryClient.invalidateQueries({ queryKey: queryKeys.projectGitBranchesRoot });
						break;
					}
					case "message_created":
					case "terminal_command_finished":
					case "terminal_command_started":
					case "terminal_entry_appended": {
						void queryClient.invalidateQueries({ queryKey: queryKeys.messages(activeChatId) });
						break;
					}
					case "project_created":
					case "project_deleted":
					case "project_updated": {
						void queryClient.invalidateQueries({ queryKey: queryKeys.projects });
						break;
					}
					case "selection_updated": {
						void queryClient.invalidateQueries({ queryKey: queryKeys.selection });
						break;
					}
					default: {
						break;
					}
				}
			}
		},
		[client, notifyMessageCompletion, queryClient, setSendingByChat],
	);

	const handleConnectionStateChange = useCallback((state: ConnectionState) => {
		setConnectionState(state);
		if (state !== "connected") {
			return;
		}

		realtimeRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, clientIdRef.current);
		const activeChatId = selectedChatIdRef.current;
		if (activeChatId) {
			realtimeRef.current?.sendJoinChat(activeChatId);
		}
	}, []);

	useEffect(() => {
		const realtime = createRealtimeClient({
			baseUrl: config.baseUrl,
			onConnectionStateChange: handleConnectionStateChange,
			onEvent: handleServerEvent,
			token: config.token,
		});

		realtime.connect();
		realtimeRef.current = realtime;

		return () => {
			realtime.disconnect();
			realtimeRef.current = null;
		};
	}, [config.baseUrl, config.token, handleConnectionStateChange, handleServerEvent]);

	useEffect(() => {
		if (!selectedChatId || !realtimeRef.current) {
			return;
		}

		realtimeRef.current.sendJoinChat(selectedChatId);
	}, [selectedChatId]);

	useEffect(() => {
		const subscription = AppState.addEventListener("change", (nextState) => {
			const previousState = appStateRef.current;
			appStateRef.current = nextState;
			const isReturningToForeground =
				(previousState === "background" || previousState === "inactive") && nextState === "active";

			if (!isReturningToForeground) {
				return;
			}

			realtimeRef.current?.connect();
			realtimeRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, clientIdRef.current);

			const activeProjectId = selectedProjectIdRef.current;
			if (activeProjectId) {
				void queryClient.invalidateQueries({
					queryKey: queryKeys.chats(activeProjectId),
				});
			}

			const activeChatId = selectedChatIdRef.current;
			if (!activeChatId) {
				return;
			}

			realtimeRef.current?.sendJoinChat(activeChatId);
			void queryClient.invalidateQueries({
				queryKey: queryKeys.messages(activeChatId),
			});
			void syncMissedAssistantEventsForChat(activeChatId);
		});

		return () => {
			subscription.remove();
		};
	}, [queryClient, syncMissedAssistantEventsForChat]);

	useEffect(() => {
		let canceled = false;
		if (!selectedChatId) {
			return () => {
				canceled = true;
			};
		}

		const collectEvents = async (
			afterId: number,
			accumulator: ChatStreamEventDTO[],
			lastEventId: number,
		): Promise<{ events: ChatStreamEventDTO[]; lastEventId: number }> => {
			const page = await client.listChatStreamEvents(selectedChatId, {
				afterId,
				limit: 500,
			});
			const nextEvents = [...accumulator, ...page.events];
			const nextLastEventId = page.events.reduce(
				(currentMax, item) => Math.max(currentMax, item.id),
				lastEventId,
			);

			if (!page.hasMore || page.nextAfterId === null) {
				return {
					events: nextEvents,
					lastEventId: nextLastEventId,
				};
			}

			return await collectEvents(page.nextAfterId, nextEvents, nextLastEventId);
		};

		void (async () => {
			try {
				const { events, lastEventId } = await collectEvents(0, [], 0);

				if (canceled) {
					return;
				}

					const turns = replayAssistantEventsIntoTurns(events);
					lastAssistantEventIdByChatRef.current[selectedChatId] = lastEventId;
				setStreamHistoryByChat((current) => ({
					...current,
					[selectedChatId]: turns,
				}));
				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(selectedChatId),
					turns.at(-1) ?? null,
				);
			} catch {
				if (canceled) {
					return;
				}
				lastAssistantEventIdByChatRef.current[selectedChatId] = 0;
				setStreamHistoryByChat((current) => ({
					...current,
					[selectedChatId]: [],
				}));
				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(selectedChatId),
					null,
				);
			}
		})();

		return () => {
			canceled = true;
		};
	}, [client, queryClient, selectedChatId]);

	const persistSelection = useCallback(
		(input: {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode?: string | null;
			selectedModel?: string | null;
			selectedReasoningEffort?: string | null;
		}) => {
			const nextSelection = normalizeSelection({
				selectedProjectId: input.selectedProjectId,
				selectedChatId: input.selectedChatId,
				permissionMode: input.permissionMode ?? permissionMode,
				selectedModel: input.selectedModel ?? selectedModel,
				selectedReasoningEffort: input.selectedReasoningEffort ?? selectedReasoningEffort,
			});
			pendingSelectionRef.current = nextSelection;
			queryClient.setQueryData(queryKeys.selection, nextSelection);

			updateSelectionMutation.mutate(nextSelection, {
				onSettled: (result, error) => {
					void result;
					if (pendingSelectionRef.current && hasSameSelection(pendingSelectionRef.current, nextSelection)) {
						pendingSelectionRef.current = null;
					}
					if (error) {
						void queryClient.invalidateQueries({ queryKey: queryKeys.selection });
					}
				},
			});
		},
		[permissionMode, queryClient, selectedModel, selectedReasoningEffort, updateSelectionMutation],
	);

	const setPermissionModeWithSync = useCallback(
		(value: string) => {
			setPermissionMode(value);
			persistSelection({
				selectedProjectId,
				selectedChatId,
				permissionMode: value,
			});
		},
		[persistSelection, selectedChatId, selectedProjectId],
	);

	const setSelectedModelWithSync = useCallback(
		(value: string | null) => {
			setSelectedModel(value);
			persistSelection({
				selectedProjectId,
				selectedChatId,
				selectedModel: value,
			});
		},
		[persistSelection, selectedChatId, selectedProjectId],
	);

	const setSelectedReasoningEffortWithSync = useCallback(
		(value: string | null) => {
			setSelectedReasoningEffort(value);
			persistSelection({
				selectedProjectId,
				selectedChatId,
				selectedReasoningEffort: value,
			});
		},
		[persistSelection, selectedChatId, selectedProjectId],
	);

	const selectProject = useCallback(
		(project: ProjectDTO) => {
			inMemorySelectedProjectId = project.id;
			inMemorySelectedChatId = null;
			setSelectedProjectId(project.id);
			setSelectedChatId(null);
			setLastError(null);

			persistSelection({
				selectedChatId: null,
				selectedProjectId: project.id,
			});
		},
		[persistSelection],
	);

	const selectChat = useCallback(
		(chat: ChatDTO) => {
			inMemorySelectedProjectId = chat.projectId;
			inMemorySelectedChatId = chat.id;
			setSelectedProjectId(chat.projectId);
			setSelectedChatId(chat.id);
			setLastError(null);

			persistSelection({
				selectedChatId: chat.id,
				selectedProjectId: chat.projectId,
			});

			realtimeRef.current?.sendJoinChat(chat.id);
		},
		[persistSelection],
	);

	const toggleFavorite = useCallback(
		async (project: ProjectDTO) => {
			await toggleFavoriteMutation.mutateAsync({
				isFavorite: !project.isFavorite,
				projectId: project.id,
			});
		},
		[toggleFavoriteMutation],
	);

	const deleteChat = useCallback(
		async (chatId: string) => {
			await deleteChatMutation.mutateAsync(chatId);
			pendingSendChatIdsRef.current.delete(chatId);
			pendingCompletionNotificationChatIdsRef.current.delete(chatId);

			if (selectedChatId === chatId) {
				inMemorySelectedChatId = null;
				setSelectedChatId(null);
				persistSelection({
					selectedChatId: null,
					selectedProjectId,
				});
			}
		},
		[deleteChatMutation, persistSelection, selectedChatId, selectedProjectId],
	);

	const createChat = useCallback(
		async (title?: string): Promise<ChatDTO | null> => {
			if (!selectedProjectId) {
				return null;
			}

			const chat = await createChatMutation.mutateAsync({
				projectId: selectedProjectId,
				title,
			});

			inMemorySelectedProjectId = selectedProjectId;
			inMemorySelectedChatId = chat.id;
			setSelectedChatId(chat.id);
			persistSelection({
				selectedChatId: chat.id,
				selectedProjectId,
			});
			realtimeRef.current?.sendJoinChat(chat.id);

			return chat;
		},
		[createChatMutation, persistSelection, selectedProjectId],
	);

	const createProject = useCallback(
		async (input: { name?: string; path: string }) => {
			const project = await client.createProject(input);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });

			inMemorySelectedProjectId = project.id;
			inMemorySelectedChatId = null;
			setSelectedProjectId(project.id);
			setSelectedChatId(null);
			persistSelection({
				selectedChatId: null,
				selectedProjectId: project.id,
			});

			return project;
		},
		[client, persistSelection, queryClient],
	);

	const deleteProject = useCallback(
		async (projectId: string) => {
			await client.deleteProject(projectId);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });

			if (selectedProjectId === projectId) {
				inMemorySelectedProjectId = null;
				inMemorySelectedChatId = null;
				setSelectedProjectId(null);
				setSelectedChatId(null);
				persistSelection({
					selectedChatId: null,
					selectedProjectId: null,
				});
			}
		},
		[client, persistSelection, queryClient, selectedProjectId],
	);

	const sendMessage = useMutation({
		mutationFn: async (rawText: string) => {
			const text = rawText.trim();

			if (!selectedProjectId || text.length === 0) {
				return false;
			}

			const selectedChat = chatsQuery.data?.find((chat) => chat.id === selectedChatId) ?? null;
			if (selectedChat?.status === "running") {
				setLastError("This thread is currently running. Wait until it finishes.");
				return false;
			}
			const selectedChatHasNoMessages = messagesQuery.messages.length === 0;
			const replacementChat =
				selectedChat &&
				selectedChatHasNoMessages &&
				isPlaceholderThreadTitle(selectedChat.title)
					? await createChat(text)
					: null;
			const placeholderChatIdToDelete =
				replacementChat && selectedChat ? selectedChat.id : null;
			const fallbackChat =
				replacementChat || selectedChatId ? null : await createChat(text);
			const activeChatId =
				replacementChat?.id ??
				selectedChatId ??
				fallbackChat?.id ??
				null;

			if (!activeChatId) {
				return false;
			}

			const nextMessage: MessageDTO = {
				chatId: activeChatId,
				content: text,
				createdAt: new Date().toISOString(),
				id: `user-${Date.now()}`,
				role: "user",
			};

			queryClient.setQueryData<InfiniteData<MessagePageDTO>>(
				queryKeys.messages(activeChatId),
				(current) => appendMessageToMessagePages(current, nextMessage),
			);
			queryClient.setQueryData(queryKeys.streamTurn(activeChatId), null);
			setStreamingTextByChat((current) => ({
				...current,
				[activeChatId]: "",
			}));
			setLastError(null);
			setSendingByChat((current) => ({
				...current,
				[activeChatId]: true,
			}));
			pendingSendChatIdsRef.current.add(activeChatId);
			pendingCompletionNotificationChatIdsRef.current.add(activeChatId);
			void ensureLocalNotificationPermission();

			realtimeRef.current?.sendJoinChat(activeChatId);
			realtimeRef.current?.sendUserMessage(activeChatId, text, {
				clientId: clientIdRef.current,
				model: selectedModel ?? undefined,
				permissionMode,
				reasoningEffort: selectedReasoningEffort ?? undefined,
				requestId: toRequestId(),
			});
			if (placeholderChatIdToDelete) {
				try {
					await deleteChatMutation.mutateAsync(placeholderChatIdToDelete);
				} catch {
					// Ignore placeholder cleanup failure.
				}
			}

			return true;
		},
		onError: (error: unknown) => {
			const selected = selectedChatIdRef.current;
			if (selected) {
				pendingSendChatIdsRef.current.delete(selected);
				pendingCompletionNotificationChatIdsRef.current.delete(selected);
				setSendingByChat((current) => ({
					...current,
					[selected]: false,
				}));
			}
			setLastError(error instanceof Error ? error.message : "Failed to send message");
		},
	});

	const setStreamItemExpanded = useCallback(
		(itemId: string, expanded: boolean, byUser: boolean) => {
			if (!selectedChatId) {
				return;
			}

			queryClient.setQueryData<StreamTurnState | null>(
				queryKeys.streamTurn(selectedChatId),
				(current) =>
					current
						? updateStreamItemExpanded(current, itemId, {
							expanded,
							byUser,
						})
						: current ?? null,
			);
			setStreamHistoryByChat((current) => {
				const turns = current[selectedChatId] ?? [];
				const nextTurns = turns.map((turn) => (
					turn.turnId === (queryClient.getQueryData<StreamTurnState | null>(queryKeys.streamTurn(selectedChatId))?.turnId ?? "")
						? updateStreamItemExpanded(turn, itemId, {
							expanded,
							byUser,
						})
						: turn
				));
				return {
					...current,
					[selectedChatId]: nextTurns,
				};
			});
		},
		[queryClient, selectedChatId],
	);

	const setStreamItemState = useCallback(
		(itemId: string, state: AssistantStreamItemState) => {
			if (!selectedChatId) {
				return;
			}

			queryClient.setQueryData<StreamTurnState | null>(
				queryKeys.streamTurn(selectedChatId),
				(current) => (current ? updateStreamItemState(current, itemId, state) : current ?? null),
			);
			setStreamHistoryByChat((current) => {
				const turns = current[selectedChatId] ?? [];
				const nextTurns = turns.map((turn) => (
					turn.turnId === (queryClient.getQueryData<StreamTurnState | null>(queryKeys.streamTurn(selectedChatId))?.turnId ?? "")
						? updateStreamItemState(turn, itemId, state)
						: turn
				));
				return {
					...current,
					[selectedChatId]: nextTurns,
				};
			});
		},
		[queryClient, selectedChatId],
	);

	const selectedProject = useMemo(
		() => projectsQuery.data?.find((project) => project.id === selectedProjectId) ?? null,
		[projectsQuery.data, selectedProjectId],
	);

	const selectedChat = useMemo(
		() => chatsQuery.data?.find((chat) => chat.id === selectedChatId) ?? null,
		[chatsQuery.data, selectedChatId],
	);

	useEffect(() => {
		if (!selectedChatId || !selectedChat) {
			return;
		}

		if (selectedChat.status !== "completed" && selectedChat.status !== "failed") {
			return;
		}

		notifyMessageCompletion(selectedChatId, selectedChat.status);
	}, [notifyMessageCompletion, selectedChat, selectedChatId]);

	const streamingText = selectedChatId ? streamingTextByChat[selectedChatId] ?? "" : "";
	const streamHistoryTurns = selectedChatId ? streamHistoryByChat[selectedChatId] ?? [] : [];
	const isSending = selectedChatId ? Boolean(sendingByChat[selectedChatId]) : false;
	const isChatsLoading = Boolean(selectedProjectId) && chatsQuery.isPending;
	const messages = messagesQuery.messages;
	const isMessagesLoading = Boolean(selectedChatId) && messagesQuery.isPending && messages.length === 0;

	return {
		availableModels: modelsQuery.data?.models ?? [],
		chats: chatsQuery.data ?? [],
		connectionState,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		hasOlderMessages: messagesQuery.hasOlderMessages,
		isLoaded: !projectsQuery.isLoading && selectionQuery.isFetched,
		isLoadingOlderMessages: messagesQuery.isLoadingOlderMessages,
		isChatsLoading,
		isMessagesLoading,
		isSending,
		lastError,
		loadOlderMessages: messagesQuery.loadOlderMessages,
		messages,
		permissionMode,
		projects: projectsQuery.data ?? [],
		selectedModel,
		selectedReasoningEffort,
		selectChat,
		selectProject,
		setPermissionMode: setPermissionModeWithSync,
		setSelectedModel: setSelectedModelWithSync,
		setSelectedReasoningEffort: setSelectedReasoningEffortWithSync,
		setStreamItemExpanded,
		setStreamItemState,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage: sendMessage.mutateAsync,
		streamHistoryTurns,
		streamingText,
		streamingTurn: streamTurnQuery.data ?? null,
		toggleFavorite,
	};
};
