import { useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AppState, type AppStateStatus } from "react-native";

import { useChatsQuery } from "../api/use-chats-query";
import { useChatContextQuery } from "../api/use-chat-context-query";
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
	ChatContextDTO,
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
	clearThreadLiveActivity,
	finishThreadLiveActivity,
	onThreadLiveActivityAppStateChanged,
	startThreadLiveActivity,
	updateThreadLiveActivity,
} from "../../../shared/live-activity/thread-live-activity";
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

type WorkspaceShellScope = "legacy" | "workspaces" | "threads" | "chat";

interface UseWorkspaceShellOptions {
	scope?: WorkspaceShellScope;
	shouldLoadDrawerWorkspaces?: boolean;
	isActive?: boolean;
}

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

const asRecord = (value: unknown): Record<string, unknown> | null => (
	typeof value === "object" &&
	value !== null &&
	!Array.isArray(value)
		? value as Record<string, unknown>
		: null
);

const asNullableString = (value: unknown): string | null =>
	typeof value === "string" ? value : null;

const extractWorkspaceEventChatId = (payload: Record<string, unknown> | null): string | null => {
	if (!payload) {
		return null;
	}

	const payloadChat = asRecord(payload.chat);
	const payloadMessage = asRecord(payload.message);
	const payloadCommand = asRecord(payload.command);
	const payloadEntry = asRecord(payload.entry);

	return (
		asNullableString(payload.chatId) ??
		asNullableString(payloadChat?.id) ??
		asNullableString(payloadMessage?.chatId) ??
		asNullableString(payloadCommand?.chatId) ??
		asNullableString(payloadEntry?.chatId) ??
		null
	);
};

const extractWorkspaceEventProjectId = (payload: Record<string, unknown> | null): string | null => {
	if (!payload) {
		return null;
	}

	const payloadProject = asRecord(payload.project);
	const payloadChat = asRecord(payload.chat);
	const payloadSelection = asRecord(payload.selection);

	return (
		asNullableString(payload.projectId) ??
		asNullableString(payloadProject?.id) ??
		asNullableString(payloadChat?.projectId) ??
		asNullableString(payloadSelection?.selectedProjectId) ??
		null
	);
};

const parseWorkspaceEventMessage = (payload: Record<string, unknown> | null): MessageDTO | null => {
	const rawMessage = asRecord(payload?.message);
	if (!rawMessage) {
		return null;
	}

	const role = rawMessage.role;
	if (role !== "assistant" && role !== "user") {
		return null;
	}

	const id = asNullableString(rawMessage.id);
	const chatId = asNullableString(rawMessage.chatId);
	const content = asNullableString(rawMessage.content);
	const createdAt = asNullableString(rawMessage.createdAt);
	if (!id || !chatId || content === null || !createdAt) {
		return null;
	}

	return {
		id,
		chatId,
		content,
		createdAt,
		role,
	};
};

const parseWorkspaceEventSelection = (payload: Record<string, unknown> | null): WorkspaceSelectionDTO | null => {
	const rawSelection = asRecord(payload?.selection);
	if (!rawSelection) {
		return null;
	}

	return normalizeSelection({
		selectedProjectId: asNullableString(rawSelection.selectedProjectId),
		selectedChatId: asNullableString(rawSelection.selectedChatId),
		permissionMode: asNullableString(rawSelection.permissionMode) ?? "default",
		selectedModel: asNullableString(rawSelection.selectedModel),
		selectedReasoningEffort: asNullableString(rawSelection.selectedReasoningEffort),
	});
};

let inMemorySelectedProjectId: string | null = null;
let inMemorySelectedChatId: string | null = null;

const toProjectDtoFromSummary = (project: { id: string; name: string; path: string }): ProjectDTO => ({
	createdAt: "",
	id: project.id,
	isFavorite: false,
	name: project.name,
	path: project.path,
	updatedAt: "",
});

const toChatDtoFromThreadSummary = (
	chat: { id: string; title: string; updatedAt: string },
	projectId: string | null,
): ChatDTO => ({
	diffAdded: 0,
	diffRemoved: 0,
	id: chat.id,
	projectId: projectId ?? "",
	provider: "codex",
	status: "pending",
	title: chat.title,
	updatedAt: chat.updatedAt,
});

export const useWorkspaceShell = (options?: UseWorkspaceShellOptions) => {
	const queryClient = useQueryClient();
	const { config } = useApiConfig();
	const scope = options?.scope ?? "legacy";
	const isActive = options?.isActive ?? true;
	const shouldLoadDrawerWorkspaces = options?.shouldLoadDrawerWorkspaces ?? (scope === "legacy" || scope === "workspaces");
	const shouldLoadWorkspaceSummaries = isActive && scope !== "legacy";
	const shouldEnableProjectsQuery = isActive && (scope === "legacy" || scope === "workspaces" || shouldLoadDrawerWorkspaces);
	const shouldEnableChatsQuery = isActive && (scope === "legacy" || scope === "threads");
	const shouldLoadThreadSummaries = isActive && scope === "threads";
	const shouldEnableMessagesQuery = isActive && (scope === "legacy" || scope === "chat");
	const shouldEnableChatContextQuery = isActive && scope === "chat";
	const shouldEnableSelectionQuery = isActive;
	const shouldEnableModelsQuery = isActive && (scope === "legacy" || scope === "chat");
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
	const projectsQuery = useProjectsQuery({
		enabled: shouldEnableProjectsQuery,
		gcTime: shouldLoadWorkspaceSummaries ? 15 * 60_000 : undefined,
		mode: shouldLoadWorkspaceSummaries ? "summary" : "full",
		staleTime: shouldLoadWorkspaceSummaries ? 60_000 : undefined,
	});
	const chatsQuery = useChatsQuery(selectedProjectId, {
		enabled: shouldEnableChatsQuery,
		mode: shouldLoadThreadSummaries ? "summary" : "full",
	});
	const chatContextQuery = useChatContextQuery(selectedChatId, {
		enabled: shouldEnableChatContextQuery,
	});
	const messagesQuery = useMessagesQuery(shouldEnableMessagesQuery ? selectedChatId : null, {
		enabled: shouldEnableMessagesQuery,
	});
	const selectionQuery = useWorkspaceSelectionQuery({
		enabled: shouldEnableSelectionQuery,
	});
	const toggleFavoriteMutation = useToggleFavoriteMutation();
	const deleteChatMutation = useDeleteChatMutation(selectedProjectId);
	const modelsQuery = useQuery({
		enabled: shouldEnableModelsQuery,
		queryKey: ["codex-models"],
		queryFn: async () => await client.listCodexModels(),
		staleTime: 5 * 60_000,
	});

	const invalidateWorkspaceQuery = useCallback((queryKey: readonly unknown[]) => {
		void queryClient.invalidateQueries({ queryKey }, {
			cancelRefetch: false,
		});
	}, [queryClient]);

	const invalidateSelectedProjectGitQueries = useCallback(() => {
		const activeProjectId = selectedProjectIdRef.current;
		if (!activeProjectId) {
			return;
		}

		invalidateWorkspaceQuery(queryKeys.projectGitStatus(activeProjectId));
		invalidateWorkspaceQuery(queryKeys.projectGitBranches(activeProjectId));
	}, [invalidateWorkspaceQuery]);

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

	const projects = useMemo<ProjectDTO[]>(() => {
		const rawProjects = (projectsQuery.data ?? []) as (ProjectDTO | { id: string; name: string; path: string })[];
		return rawProjects.map((project) => (
			"isFavorite" in project
				? project
				: toProjectDtoFromSummary(project)
		));
	}, [projectsQuery.data]);

	const chats = useMemo<ChatDTO[]>(() => {
		const rawChats = (chatsQuery.data ?? []) as (ChatDTO | { id: string; title: string; updatedAt: string })[];
		return rawChats.map((chat) => (
			"projectId" in chat
				? chat
				: toChatDtoFromThreadSummary(chat, selectedProjectId)
		));
	}, [chatsQuery.data, selectedProjectId]);

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

	const resolveChatTitle = useCallback(
		(chatId: string): string | undefined => {
			const contextTitle = queryClient.getQueryData<ChatContextDTO>(queryKeys.chatContext(chatId))?.chat.title?.trim();
			if (contextTitle && contextTitle.length > 0) {
				return contextTitle;
			}

			const title = chats.find((chat) => chat.id === chatId)?.title?.trim();
			return title && title.length > 0 ? title : undefined;
		},
		[chats, queryClient],
	);

	const startRunningLiveActivity = useCallback(
		(chatId: string, input?: { chatTitle?: string; statusLine?: string }) => {
			const title = input?.chatTitle?.trim() || resolveChatTitle(chatId);

			void startThreadLiveActivity({
				chatId,
				chatTitle: title,
				statusLine: input?.statusLine ?? "Running",
			});
		},
		[resolveChatTitle],
	);

	const updateRunningLiveActivity = useCallback(
		(input: {
			chatId: string;
			chatTitle?: string;
			phase?: "running" | "background" | "finalizing";
			preview?: string;
			statusLine?: string;
			force?: boolean;
		}) => {
			const title = input.chatTitle?.trim() || resolveChatTitle(input.chatId);

			void updateThreadLiveActivity({
				chatId: input.chatId,
				chatTitle: title,
				phase: input.phase,
				preview: input.preview,
				statusLine: input.statusLine,
				force: input.force,
			});
		},
		[resolveChatTitle],
	);

	const finishLiveActivity = useCallback(
		(chatId: string, input: { outcome: "completed" | "failed" | "error"; statusLine?: string }) => {
			const title = resolveChatTitle(chatId);
			void finishThreadLiveActivity({
				chatId,
				chatTitle: title,
				outcome: input.outcome,
				statusLine: input.statusLine,
			});
		},
		[resolveChatTitle],
	);

	const notifyMessageCompletion = useCallback(
		(chatId: string, outcome: "completed" | "error" | "failed") => {
			if (!pendingCompletionNotificationChatIdsRef.current.has(chatId)) {
				return;
			}

			pendingCompletionNotificationChatIdsRef.current.delete(chatId);
			const chatTitle = resolveChatTitle(chatId);

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
		[resolveChatTitle],
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
				const chatId = event.data.chatId;
				setStreamingTextByChat((current) => ({
					...current,
					[chatId]: (() => {
						const nextPreview = `${current[chatId] ?? ""}${event.data.delta}`;
						updateRunningLiveActivity({
							chatId,
							phase: "running",
							preview: nextPreview,
							statusLine: "Generating response",
						});
						return nextPreview;
					})(),
				}));
				clearSendingForChat(chatId);
				return;
			}

			if (event.event === "assistant_snapshot") {
				setStreamingTextByChat((current) => ({
					...current,
					[event.data.chatId]: event.data.partialText,
				}));
				updateRunningLiveActivity({
					chatId: event.data.chatId,
					preview: event.data.partialText,
				});
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
				const statusLine = (() => {
					switch (event.data.event.type) {
						case "item_completed": {
							return event.data.event.summary ?? "Step completed";
						}
						case "item_started": {
							return event.data.event.summary ?? "Working...";
						}
						case "item_state": {
							return event.data.event.summary ?? `Step ${event.data.event.state}`;
						}
						case "turn_completed": {
							return "Finalizing response";
						}
						default: {
							return undefined;
						}
					}
				})();
				const eventPreview = (() => {
					switch (event.data.event.type) {
						case "item_completed":
						case "item_started":
						case "item_state": {
							return event.data.event.summary;
						}
						default: {
							return undefined;
						}
					}
				})();
				updateRunningLiveActivity({
					chatId,
					phase: event.data.event.type === "turn_completed" ? "finalizing" : "running",
					preview: eventPreview,
					statusLine,
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
				if (selectedChatIdRef.current === chatId) {
					invalidateSelectedProjectGitQueries();
					invalidateWorkspaceQuery(queryKeys.chatContext(chatId));
				}
				finishLiveActivity(chatId, {
					outcome: "completed",
					statusLine: "Response is ready",
				});
				notifyMessageCompletion(chatId, "completed");
				return;
			}

			if (event.event === "chat_updated") {
				const activeProjectId = selectedProjectIdRef.current;
				if (activeProjectId && shouldEnableChatsQuery) {
					invalidateWorkspaceQuery(queryKeys.chats(activeProjectId));
				}
				queryClient.setQueryData<ChatContextDTO>(
					queryKeys.chatContext(event.data.chatId),
					(current) => (
						current
							? {
								...current,
								chat: {
									...current.chat,
									diffAdded: event.data.diffAdded,
									diffRemoved: event.data.diffRemoved,
									status: event.data.status,
									updatedAt: event.data.updatedAt,
								},
							}
							: current
					),
				);
				if (event.data.status !== "running") {
					clearSendingForChat(event.data.chatId);
				}
				const shouldTrackLiveActivity =
					pendingCompletionNotificationChatIdsRef.current.has(event.data.chatId) ||
					selectedChatIdRef.current === event.data.chatId;
				if (event.data.status === "running" && shouldTrackLiveActivity) {
					startRunningLiveActivity(event.data.chatId, {
						statusLine: "Running",
					});
				}
				if ((event.data.status === "completed" || event.data.status === "failed") && shouldTrackLiveActivity) {
					finishLiveActivity(event.data.chatId, {
						outcome: event.data.status,
					});
					notifyMessageCompletion(event.data.chatId, event.data.status);
				}
				if (
					selectedChatIdRef.current === event.data.chatId
					&& (event.data.status === "completed" || event.data.status === "failed")
				) {
					invalidateSelectedProjectGitQueries();
					invalidateWorkspaceQuery(queryKeys.chatContext(event.data.chatId));
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
					finishLiveActivity(chatId, {
						outcome: "error",
					});
					notifyMessageCompletion(chatId, "error");
				}
				return;
			}

			if (event.event === "workspace_event") {
				lastWorkspaceSeqRef.current = Math.max(lastWorkspaceSeqRef.current, event.data.seq);
				const activeProjectId = selectedProjectIdRef.current;
				const activeChatId = selectedChatIdRef.current;
				const workspacePayload = asRecord(event.data.payload);
				const workspaceChatId = extractWorkspaceEventChatId(workspacePayload);
				const workspaceProjectId = extractWorkspaceEventProjectId(workspacePayload);
				const workspaceMessage = parseWorkspaceEventMessage(workspacePayload);
				const workspaceSelection = parseWorkspaceEventSelection(workspacePayload);
				const isSelfOriginatedWorkspaceEvent =
					event.data.originClientId !== null &&
					event.data.originClientId === clientIdRef.current;

				if (isSelfOriginatedWorkspaceEvent) {
					return;
				}

				switch (event.data.type) {
					case "chat_created":
					case "chat_deleted":
					case "chat_updated": {
						if (activeChatId && workspaceChatId && workspaceChatId === activeChatId) {
							invalidateWorkspaceQuery(queryKeys.chatContext(activeChatId));
						}

						if (!activeProjectId) {
							break;
						}

						if (workspaceProjectId && workspaceProjectId !== activeProjectId) {
							break;
						}

						if (!workspaceProjectId && workspaceChatId) {
							const cachedChats = queryClient.getQueriesData<ChatDTO[] | { id: string }[]>({
								queryKey: queryKeys.chats(activeProjectId),
							});
							const hasCachedChat = cachedChats.some(([, value]) =>
								Array.isArray(value) && value.some((chat) => chat.id === workspaceChatId)
							);
							if (!hasCachedChat) {
								break;
							}
						}

						invalidateWorkspaceQuery(queryKeys.chats(activeProjectId));
						break;
					}
					case "git_updated": {
						if (!activeProjectId) {
							break;
						}

						if (workspaceProjectId && workspaceProjectId !== activeProjectId) {
							break;
						}

						invalidateWorkspaceQuery(queryKeys.projectGitStatus(activeProjectId));
						invalidateWorkspaceQuery(queryKeys.projectGitBranches(activeProjectId));
						break;
					}
					case "message_created": {
						if (!activeChatId) {
							break;
						}

						if (workspaceChatId && workspaceChatId !== activeChatId) {
							break;
						}

						if (workspaceMessage && workspaceMessage.chatId === activeChatId) {
							const messagesQueryKey = queryKeys.messages(activeChatId);
							const currentPages = queryClient.getQueryData<InfiniteData<MessagePageDTO>>(
								messagesQueryKey,
							);
							if (!currentPages) {
								invalidateWorkspaceQuery(messagesQueryKey);
								break;
							}

							queryClient.setQueryData<InfiniteData<MessagePageDTO>>(
								messagesQueryKey,
								(current) => {
									const hasMessage = (current?.pages ?? []).some((page) =>
										page.messages.some((message) => message.id === workspaceMessage.id)
									);
									if (hasMessage) {
										return current;
									}

									return appendMessageToMessagePages(current, workspaceMessage);
								},
							);
							break;
						}

						invalidateWorkspaceQuery(queryKeys.messages(activeChatId));
						break;
					}
					case "project_created":
					case "project_deleted":
					case "project_updated": {
						invalidateWorkspaceQuery(queryKeys.projects);
						break;
					}
					case "selection_updated": {
						if (workspaceSelection) {
							queryClient.setQueryData(queryKeys.selection, workspaceSelection);
							break;
						}

						invalidateWorkspaceQuery(queryKeys.selection);
						break;
					}
					case "terminal_command_finished":
					case "terminal_command_started":
					case "terminal_entry_appended": {
						// Terminal updates are handled outside the messages query.
						break;
					}
					default: {
						break;
					}
				}
			}
		},
		[
			client,
			finishLiveActivity,
			invalidateSelectedProjectGitQueries,
			notifyMessageCompletion,
			queryClient,
			setSendingByChat,
			shouldEnableChatsQuery,
			startRunningLiveActivity,
			invalidateWorkspaceQuery,
			updateRunningLiveActivity,
		],
	);

	const handleConnectionStateChange = useCallback((state: ConnectionState) => {
		setConnectionState(state);
		if (state !== "connected") {
			return;
		}

		realtimeRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, clientIdRef.current);
		const activeChatId = selectedChatIdRef.current;
		if (activeChatId && shouldEnableMessagesQuery) {
			realtimeRef.current?.sendJoinChat(activeChatId);
		}
	}, [shouldEnableMessagesQuery]);

	useEffect(function handleWorkspaceRealtimeEffect() {
		if (!isActive) {
			setConnectionState("idle");
			return;
		}

		const realtime = createRealtimeClient({
			baseUrl: config.baseUrl,
			onConnectionStateChange: handleConnectionStateChange,
			onEvent: handleServerEvent,
			token: config.token,
		});

		realtime.connect();
		realtimeRef.current = realtime;

		// eslint-disable-next-line @typescript-eslint/consistent-return
		return () => {
			realtime.disconnect();
			realtimeRef.current = null;
		};
	}, [config.baseUrl, config.token, handleConnectionStateChange, handleServerEvent, isActive]);

	useEffect(() => {
		if (!shouldEnableMessagesQuery || !selectedChatId || !realtimeRef.current) {
			return;
		}

		realtimeRef.current.sendJoinChat(selectedChatId);
	}, [selectedChatId, shouldEnableMessagesQuery]);

	useEffect(function handleAppStateEffect() {
		if (!isActive) {
			return;
		}

		const subscription = AppState.addEventListener("change", (nextState) => {
			const previousState = appStateRef.current;
			appStateRef.current = nextState;
			void onThreadLiveActivityAppStateChanged(nextState);
			const isReturningToForeground =
				(previousState === "background" || previousState === "inactive") && nextState === "active";

			if (!isReturningToForeground) {
				return;
			}

			realtimeRef.current?.connect();
			realtimeRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, clientIdRef.current);

			const activeProjectId = selectedProjectIdRef.current;
			if (activeProjectId && shouldEnableChatsQuery) {
				void queryClient.invalidateQueries({
					queryKey: queryKeys.chats(activeProjectId),
				});
			}

			const activeChatId = selectedChatIdRef.current;
			if (!activeChatId || !shouldEnableMessagesQuery) {
				return;
			}

			updateRunningLiveActivity({
				chatId: activeChatId,
				phase: "running",
				statusLine: "Running",
				force: true,
			});
			realtimeRef.current?.sendJoinChat(activeChatId);
			void queryClient.invalidateQueries({
				queryKey: queryKeys.messages(activeChatId),
			});
		void syncMissedAssistantEventsForChat(activeChatId);
		});

		// eslint-disable-next-line @typescript-eslint/consistent-return
		return () => {
			subscription.remove();
		};
	}, [
		isActive,
		queryClient,
		shouldEnableChatsQuery,
		shouldEnableMessagesQuery,
		syncMissedAssistantEventsForChat,
		updateRunningLiveActivity,
	]);

	useEffect(() => {
		let canceled = false;
		if (!shouldEnableMessagesQuery || !selectedChatId) {
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
	}, [client, queryClient, selectedChatId, shouldEnableMessagesQuery]);

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
			void queryClient.invalidateQueries({
				queryKey: queryKeys.chats(project.id),
			});

			persistSelection({
				selectedChatId: null,
				selectedProjectId: project.id,
			});
		},
		[persistSelection, queryClient],
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
			await clearThreadLiveActivity({
				chatId,
			});

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
			if (selectedChatIdRef.current) {
				await clearThreadLiveActivity({
					chatId: selectedChatIdRef.current,
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

			const selectedChatFromList = chats.find((chat) => chat.id === selectedChatId) ?? null;
			const selectedChatFromContext = selectedChatId
				? queryClient.getQueryData<ChatContextDTO>(queryKeys.chatContext(selectedChatId))?.chat ?? null
				: null;
			const selectedChat = selectedChatFromList ?? selectedChatFromContext;
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
			startRunningLiveActivity(activeChatId, {
				chatTitle: replacementChat?.title ?? selectedChat?.title ?? fallbackChat?.title,
				statusLine: "Running",
			});

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
				finishLiveActivity(selected, {
					outcome: "error",
				});
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
		() => {
			const fromList = projects.find((project) => project.id === selectedProjectId) ?? null;
			const fromChatContext = chatContextQuery.data?.project
				? toProjectDtoFromSummary(chatContextQuery.data.project)
				: null;

			return fromList ?? fromChatContext;
		},
		[chatContextQuery.data?.project, projects, selectedProjectId],
	);

	const selectedChat = useMemo(
		() => {
			if (scope === "chat") {
				return chatContextQuery.data?.chat ?? null;
			}

			return chats.find((chat) => chat.id === selectedChatId) ?? null;
		},
		[chats, chatContextQuery.data?.chat, scope, selectedChatId],
	);

	useEffect(() => {
		if (!selectedChatId || !selectedChat) {
			return;
		}

		if (selectedChat.status !== "completed" && selectedChat.status !== "failed") {
			return;
		}

		finishLiveActivity(selectedChatId, {
			outcome: selectedChat.status,
		});
		notifyMessageCompletion(selectedChatId, selectedChat.status);
	}, [finishLiveActivity, notifyMessageCompletion, selectedChat, selectedChatId]);

	const streamingText = selectedChatId ? streamingTextByChat[selectedChatId] ?? "" : "";
	const streamHistoryTurns = selectedChatId ? streamHistoryByChat[selectedChatId] ?? [] : [];
	const isSending = selectedChatId ? Boolean(sendingByChat[selectedChatId]) : false;
	const hasChatsData = Array.isArray(chatsQuery.data);
	const isChatsLoading =
		Boolean(selectedProjectId) &&
		shouldEnableChatsQuery &&
		(chatsQuery.isPending || (chatsQuery.fetchStatus === "fetching" && !hasChatsData));
	let chatsErrorMessage: string | null = null;
	if (shouldEnableChatsQuery && chatsQuery.isError) {
		chatsErrorMessage = chatsQuery.error instanceof Error
			? chatsQuery.error.message
			: "Failed to load threads.";
	}
	const messages = shouldEnableMessagesQuery ? messagesQuery.messages : [];
	const isMessagesLoading =
		shouldEnableMessagesQuery &&
		Boolean(selectedChatId) &&
		messagesQuery.isPending &&
		messages.length === 0;
	const isProjectsLoading =
		shouldEnableProjectsQuery &&
		(projectsQuery.isPending || (projectsQuery.fetchStatus === "fetching" && projects.length === 0));

	return {
		availableModels: modelsQuery.data?.models ?? [],
		chatsErrorMessage,
		chats,
		connectionState,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		hasOlderMessages: shouldEnableMessagesQuery ? messagesQuery.hasOlderMessages : false,
		isLoaded: !isProjectsLoading && selectionQuery.isFetched,
		isLoadingOlderMessages: shouldEnableMessagesQuery ? messagesQuery.isLoadingOlderMessages : false,
		isChatsLoading,
		isMessagesLoading,
		isSending,
		lastError,
		loadOlderMessages: shouldEnableMessagesQuery ? messagesQuery.loadOlderMessages : async () => undefined,
		messages,
		permissionMode,
		projects,
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
