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
import { RemoteCodeRequestError } from "../../../shared/api/remotecode-client";
import { createRealtimeClient, type ConnectionState } from "../../../shared/api/ws-client";
import type {
	ActiveThreadSummaryDTO,
	AssistantStreamItemState,
	AssistantStreamItemType,
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
	isThreadLiveActivityEnabled,
	onThreadLiveActivityAppStateChanged,
	startThreadLiveActivity,
	subscribeThreadLiveActivityPushToken,
	updateThreadLiveActivity,
} from "../../../shared/live-activity/thread-live-activity";
import {
	ensurePushDeliveryToken,
	subscribePushDeliveryTokenRefresh,
	type PushDeliveryToken,
} from "../../../shared/notifications/firebase-messaging";
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

const toLiveActivityFallbackText = (itemType: AssistantStreamItemType): string => {
	switch (itemType) {
		case "assistant_message": {
			return "Writing response...";
		}
		case "plan": {
			return "Planning...";
		}
		case "reasoning": {
			return "Thinking...";
		}
		case "tool": {
			return "Running tool...";
		}
		default: {
			return "Working...";
		}
	}
};

const toLiveActivityPreviewFromEvent = (event: AssistantEventPayload): string | undefined => {
	switch (event.type) {
		case "item_completed": {
			return event.summary?.trim() || undefined;
		}
		case "item_delta": {
			const preview = event.delta.trim();
			return preview.length > 0 ? preview : undefined;
		}
		case "item_started": {
			return event.summary?.trim() || toLiveActivityFallbackText(event.itemType);
		}
		case "item_state": {
			return event.summary?.trim() || undefined;
		}
		case "turn_completed": {
			return undefined;
		}
		default: {
			return undefined;
		}
	}
};

const toLiveActivityPreviewFromTurn = (
	turn: StreamTurnState | null,
	event: AssistantEventPayload,
): string | undefined => {
	if (event.type === "item_delta" && event.target === "summary") {
		return toLiveActivityPreviewFromEvent(event);
	}

	if ("itemId" in event) {
		const item = turn?.itemsById[event.itemId];
		if (item) {
			const body = item.body.trim();
			if (body.length > 0) {
				return body;
			}

			const output = item.output.trim();
			if (output.length > 0) {
				return output;
			}

			const summary = item.summary.trim();
			if (summary.length > 0) {
				return summary;
			}
		}
	}

	return toLiveActivityPreviewFromEvent(event);
};

const toLiveActivityStatusLineFromEvent = (event: AssistantEventPayload): string | undefined => {
	switch (event.type) {
		case "item_completed": {
			return event.summary?.trim() || "Working...";
		}
		case "item_delta": {
			if (event.target === "summary") {
				const statusLine = event.delta.trim();
				return statusLine.length > 0 ? statusLine : undefined;
			}

			return undefined;
		}
		case "item_started": {
			return event.summary?.trim() || toLiveActivityFallbackText(event.itemType);
		}
		case "item_state": {
			return event.summary?.trim() || `Step ${event.state}`;
		}
		case "turn_completed": {
			return "Finalizing response";
		}
		default: {
			return undefined;
		}
	}
};

const isPlaceholderThreadTitle = (title: string): boolean => {
	const normalized = title.trim().toLowerCase();
	return normalized === "new thread" || normalized === "new chat";
};

const toRequestId = (): string =>
	`req-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`;

const permissionModes = ["plan", "default", "full"] as const;
const reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh"] as const;
const LIVE_ACTIVITY_SUBSCRIPTION_LOG_PREFIX = "[live-activity-subscription]";
const LIVE_ACTIVITY_SUBSCRIPTION_RETRY_INTERVAL_MS = 5_000;

const toTokenPreview = (token: string): string => (
	token.length <= 16
		? token
		: `${token.slice(0, 8)}...${token.slice(-4)}`
);

const logLiveActivitySubscription = (message: string, meta?: Record<string, unknown>): void => {
	if (meta) {
		console.log(LIVE_ACTIVITY_SUBSCRIPTION_LOG_PREFIX, message, meta);
		return;
	}

	console.log(LIVE_ACTIVITY_SUBSCRIPTION_LOG_PREFIX, message);
};

const omitRecordKey = <T>(input: Record<string, T>, key: string): Record<string, T> => {
	const { [key]: ignore, ...next } = input;
	void ignore;
	return next;
};

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

const DEFAULT_SELECTION: WorkspaceSelectionDTO = {
	permissionMode: "default",
	selectedChatId: null,
	selectedModel: null,
	selectedProjectId: null,
	selectedReasoningEffort: null,
};

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

const toProjectDtoFromSummary = (project: { id: string; name: string; path: string }): ProjectDTO => ({
	createdAt: "",
	id: project.id,
	isFavorite: false,
	name: project.name,
	path: project.path,
	updatedAt: "",
});

const toChatDtoFromThreadSummary = (
	chat: { id: string; isActive: boolean; title: string; updatedAt: string },
	projectId: string | null,
): ChatDTO => ({
	diffAdded: 0,
	diffRemoved: 0,
	id: chat.id,
	isActive: chat.isActive,
	projectId: projectId ?? "",
	provider: "codex",
	status: chat.isActive ? "running" : "pending",
	title: chat.title,
	updatedAt: chat.updatedAt,
});

export const useWorkspaceShell = (options?: UseWorkspaceShellOptions) => {
	const queryClient = useQueryClient();
	const { config } = useApiConfig();
	const initialSelectionRef = useRef<WorkspaceSelectionDTO | null>(null);
	if (!initialSelectionRef.current) {
		const cachedSelection = queryClient.getQueryData<WorkspaceSelectionDTO>(queryKeys.selection);
		initialSelectionRef.current = normalizeSelection(cachedSelection ?? DEFAULT_SELECTION);
	}

	const initialSelection = initialSelectionRef.current;
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
	const [selectedProjectId, setSelectedProjectId] = useState<string | null>(initialSelection.selectedProjectId);
	const [selectedChatId, setSelectedChatId] = useState<string | null>(initialSelection.selectedChatId);
	const [streamingTextByChat, setStreamingTextByChat] = useState<Record<string, string>>({});
	const [streamHistoryByChat, setStreamHistoryByChat] = useState<Record<string, StreamTurnState[]>>({});
	const [stoppingByChat, setStoppingByChat] = useState<Record<string, boolean>>({});
	const [permissionMode, setPermissionMode] = useState<string>(initialSelection.permissionMode);
	const [selectedModel, setSelectedModel] = useState<string | null>(initialSelection.selectedModel);
	const [selectedReasoningEffort, setSelectedReasoningEffort] = useState<string | null>(
		initialSelection.selectedReasoningEffort,
	);
	const realtimeRef = useRef<ReturnType<typeof createRealtimeClient> | null>(null);
	const lastWorkspaceSeqRef = useRef<number>(0);
	const selectedProjectIdRef = useRef<string | null>(selectedProjectId);
	const selectedChatIdRef = useRef<string | null>(selectedChatId);
	const pendingSendChatIdsRef = useRef<Set<string>>(new Set());
	const pendingCompletionNotificationChatIdsRef = useRef<Set<string>>(new Set());
	const lastSendAttemptChatIdRef = useRef<string | null>(null);
	const pushDeliveryTokenRef = useRef<PushDeliveryToken | null>(null);
	const liveActivityTokenByChatRef = useRef<Record<string, string>>({});
	const registeredLiveActivitySignatureByChatRef = useRef<Record<string, string>>({});
	const pendingLiveActivitySignatureByChatRef = useRef<Record<string, string>>({});
	const structuredLiveActivityPreviewByChatRef = useRef<Record<string, true>>({});
	const liveActivitySubscriptionRetryTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
	const flushLiveActivitySubscriptionsRef = useRef<() => void>(() => {
		// no-op
	});
	const lastAssistantEventIdByChatRef = useRef<Record<string, number>>({});
	const appStateRef = useRef<AppStateStatus>(AppState.currentState);
	const clientIdRef = useRef<string>(`mobile-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`);
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
	const activeThreadsQuery = useQuery({
		enabled: isActive,
		queryFn: async () => await client.listActiveThreads(),
		queryKey: queryKeys.activeThreads,
		refetchInterval: 2_500,
		staleTime: 1_000,
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
		const rawChats = (chatsQuery.data ?? []) as (| ChatDTO
			| { id: string; isActive?: boolean; title: string; updatedAt: string })[];
		return rawChats.map((chat) => (
			"projectId" in chat
				? chat
				: toChatDtoFromThreadSummary(
					{
						...chat,
						isActive: chat.isActive ?? false,
					},
					selectedProjectId,
				)
		));
	}, [chatsQuery.data, selectedProjectId]);

	useEffect(() => {
		if (!selectionQuery.data) {
			return;
		}

		const normalizedSelection = normalizeSelection(selectionQuery.data);
		setSelectedProjectId((current) => (
			current === normalizedSelection.selectedProjectId ? current : normalizedSelection.selectedProjectId
		));
		setSelectedChatId((current) => (
			current === normalizedSelection.selectedChatId ? current : normalizedSelection.selectedChatId
		));
		setPermissionMode((current) => (
			current === normalizedSelection.permissionMode ? current : normalizedSelection.permissionMode
		));
		setSelectedModel((current) => (
			current === normalizedSelection.selectedModel ? current : normalizedSelection.selectedModel
		));
		setSelectedReasoningEffort((current) => (
			current === normalizedSelection.selectedReasoningEffort
				? current
				: normalizedSelection.selectedReasoningEffort
		));
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
		(chatId: string, input?: { chatTitle?: string; statusLine?: string; restart?: boolean }) => {
			const title = input?.chatTitle?.trim() || resolveChatTitle(chatId);

			void startThreadLiveActivity({
				chatId,
				chatTitle: title,
				remoteManaged: true,
				restart: input?.restart,
				statusLine: input?.statusLine ?? "Generating response",
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
			authoritative?: boolean;
		}) => {
			void updateThreadLiveActivity({
				authoritative: input.authoritative,
				chatId: input.chatId,
				chatTitle: input.chatTitle,
				force: input.force,
				phase: input.phase,
				preview: input.preview,
				statusLine: input.statusLine,
			});
		},
			[],
		);

		const clearStructuredLiveActivityPreview = useCallback((chatId: string) => {
			structuredLiveActivityPreviewByChatRef.current = omitRecordKey(
				structuredLiveActivityPreviewByChatRef.current,
				chatId,
			);
		}, []);

		const finishLiveActivity = useCallback(
			(chatId: string, input: { outcome: "completed" | "failed" | "error"; statusLine?: string }) => {
				const chatTitle = resolveChatTitle(chatId);
			void finishThreadLiveActivity({
				chatId,
				chatTitle,
				outcome: input.outcome,
				statusLine: input.statusLine,
			});
			liveActivityTokenByChatRef.current = omitRecordKey(liveActivityTokenByChatRef.current, chatId);
			registeredLiveActivitySignatureByChatRef.current = omitRecordKey(
				registeredLiveActivitySignatureByChatRef.current,
				chatId,
			);
				pendingLiveActivitySignatureByChatRef.current = omitRecordKey(
					pendingLiveActivitySignatureByChatRef.current,
					chatId,
				);
				clearStructuredLiveActivityPreview(chatId);
			},
			[clearStructuredLiveActivityPreview, resolveChatTitle],
		);

	const clearLiveActivitySubscriptionRetry = useCallback(() => {
		if (!liveActivitySubscriptionRetryTimeoutRef.current) {
			return;
		}

		clearTimeout(liveActivitySubscriptionRetryTimeoutRef.current);
		liveActivitySubscriptionRetryTimeoutRef.current = null;
	}, []);

		const clearLiveActivitySubscriptionState = useCallback((chatId: string) => {
			liveActivityTokenByChatRef.current = omitRecordKey(liveActivityTokenByChatRef.current, chatId);
			registeredLiveActivitySignatureByChatRef.current = omitRecordKey(
				registeredLiveActivitySignatureByChatRef.current,
				chatId,
			);
			pendingLiveActivitySignatureByChatRef.current = omitRecordKey(
				pendingLiveActivitySignatureByChatRef.current,
				chatId,
			);
			clearStructuredLiveActivityPreview(chatId);
		}, [clearStructuredLiveActivityPreview]);

	const scheduleLiveActivitySubscriptionRetry = useCallback((input: { chatId?: string; reason: string }) => {
		if (liveActivitySubscriptionRetryTimeoutRef.current) {
			return;
		}

		logLiveActivitySubscription("scheduling subscription retry", {
			chatId: input.chatId ?? null,
			delayMs: LIVE_ACTIVITY_SUBSCRIPTION_RETRY_INTERVAL_MS,
			reason: input.reason,
		});
		liveActivitySubscriptionRetryTimeoutRef.current = setTimeout(() => {
			liveActivitySubscriptionRetryTimeoutRef.current = null;
			flushLiveActivitySubscriptionsRef.current();
		}, LIVE_ACTIVITY_SUBSCRIPTION_RETRY_INTERVAL_MS);
	}, []);

	const notifyMessageCompletion = useCallback(
		(chatId: string, outcome: "completed" | "error" | "failed") => {
			if (!pendingCompletionNotificationChatIdsRef.current.has(chatId)) {
				return;
			}

			pendingCompletionNotificationChatIdsRef.current.delete(chatId);
			if (isThreadLiveActivityEnabled()) {
				return;
			}
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

	const flushLiveActivitySubscriptions = useCallback(() => {
		const pushDeliveryToken = pushDeliveryTokenRef.current;
		const pushToken = pushDeliveryToken?.token.trim() ?? "";
		const pushTokenType = pushDeliveryToken?.type;
		if (pushToken.length === 0 || (pushTokenType !== "apns" && pushTokenType !== "fcm")) {
			logLiveActivitySubscription("flush skipped (missing push delivery token)", {
				hasPushToken: pushToken.length > 0,
				pushTokenType: pushTokenType ?? null,
			});
			return;
		}

		for (const [chatId, liveActivityToken] of Object.entries(liveActivityTokenByChatRef.current)) {
			const normalizedLiveActivityToken = liveActivityToken.trim();
			if (normalizedLiveActivityToken.length === 0) {
				logLiveActivitySubscription("flush skipped (missing live activity token)", {
					chatId,
				});
				continue;
			}

			const signature = `${pushTokenType}::${pushToken}::${normalizedLiveActivityToken}`;
			if (registeredLiveActivitySignatureByChatRef.current[chatId] === signature) {
				logLiveActivitySubscription("flush skipped (already registered)", {
					chatId,
					liveActivityToken: toTokenPreview(normalizedLiveActivityToken),
					pushToken: toTokenPreview(pushToken),
					pushTokenType,
				});
				continue;
			}
			if (pendingLiveActivitySignatureByChatRef.current[chatId] === signature) {
				logLiveActivitySubscription("flush skipped (subscription already in flight)", {
					chatId,
					liveActivityToken: toTokenPreview(normalizedLiveActivityToken),
					pushToken: toTokenPreview(pushToken),
					pushTokenType,
				});
				continue;
			}

			const chatTitle = resolveChatTitle(chatId);
			void (async () => {
				pendingLiveActivitySignatureByChatRef.current[chatId] = signature;
				logLiveActivitySubscription("sending subscription", {
					chatId,
					chatTitle: chatTitle ?? null,
					liveActivityToken: toTokenPreview(normalizedLiveActivityToken),
					pushToken: toTokenPreview(pushToken),
					pushTokenType,
				});
				try {
					const result = await client.upsertChatLiveActivitySubscription(chatId, {
						chatTitle: chatTitle?.trim().length ? chatTitle : undefined,
						pushToken,
						pushTokenType,
						liveActivityToken: normalizedLiveActivityToken,
					});
					logLiveActivitySubscription("subscription response", {
						chatId,
						enabled: result.enabled,
						subscribed: result.subscribed,
					});
					if (!result.enabled || !result.subscribed) {
						if (!result.enabled) {
							logLiveActivitySubscription("clearing live activity after disabled subscription", {
								chatId,
							});
							clearLiveActivitySubscriptionState(chatId);
							void clearThreadLiveActivity({
								chatId,
							});
							return;
						}

						logLiveActivitySubscription("subscription not accepted yet; keeping activity and retrying", {
							chatId,
						});
						scheduleLiveActivitySubscriptionRetry({
							chatId,
							reason: "subscription-not-accepted",
						});
						return;
					}

					const currentPushToken = pushDeliveryTokenRef.current?.token.trim() ?? "";
					const currentPushTokenType = pushDeliveryTokenRef.current?.type ?? null;
					const currentLiveActivityToken = liveActivityTokenByChatRef.current[chatId]?.trim() ?? "";
					if (
						currentPushToken !== pushToken
						|| currentPushTokenType !== pushTokenType
						|| currentLiveActivityToken !== normalizedLiveActivityToken
					) {
						logLiveActivitySubscription("subscription response ignored (stale token state)", {
							chatId,
						});
						return;
					}

					registeredLiveActivitySignatureByChatRef.current[chatId] = signature;
				} catch (error) {
					if (error instanceof RemoteCodeRequestError && (error.status === 400 || error.status === 404)) {
						logLiveActivitySubscription("clearing live activity after permanent subscription failure", {
							chatId,
							error: error.message,
							status: error.status,
						});
						clearLiveActivitySubscriptionState(chatId);
						void clearThreadLiveActivity({
							chatId,
						});
						return;
					}

					logLiveActivitySubscription("subscription request failed", {
						chatId,
						error: error instanceof Error ? error.message : "unknown",
					});
					scheduleLiveActivitySubscriptionRetry({
						chatId,
						reason: error instanceof Error ? error.message : "request-failed",
					});
				} finally {
					if (pendingLiveActivitySignatureByChatRef.current[chatId] === signature) {
						pendingLiveActivitySignatureByChatRef.current = omitRecordKey(
							pendingLiveActivitySignatureByChatRef.current,
							chatId,
						);
					}
				}
			})();
		}
	}, [clearLiveActivitySubscriptionState, client, resolveChatTitle, scheduleLiveActivitySubscriptionRetry]);

	useEffect(() => {
		flushLiveActivitySubscriptionsRef.current = flushLiveActivitySubscriptions;
	}, [flushLiveActivitySubscriptions]);

	useEffect(() => {
		let canceled = false;

		const storePushDeliveryToken = (
			token: PushDeliveryToken,
			reason: "initial" | "foreground retry" | "refresh",
		): void => {
			const normalized = token.token.trim();
			if (normalized.length === 0) {
				return;
			}

			pushDeliveryTokenRef.current = {
				...token,
				token: normalized,
			};
			logLiveActivitySubscription(`${reason} push delivery token stored`, {
				pushToken: toTokenPreview(normalized),
				pushTokenType: token.type,
			});
			flushLiveActivitySubscriptions();
		};

		const syncPushDeliveryToken = async (
			reason: "initial" | "foreground retry",
		): Promise<void> => {
			const token = await ensurePushDeliveryToken();
			if (canceled || !token || token.token.trim().length === 0) {
				logLiveActivitySubscription(`${reason} push delivery token unavailable`, {
					canceled,
					hasToken: Boolean(token?.token.trim().length),
				});
				return;
			}

			storePushDeliveryToken(token, reason);
		};

		void syncPushDeliveryToken("initial");

		const unsubscribe = subscribePushDeliveryTokenRefresh((token) => {
			if (canceled) {
				return;
			}

			storePushDeliveryToken(token, "refresh");
		});
			const appStateSubscription = AppState.addEventListener("change", (nextState) => {
				if (canceled || nextState !== "active") {
					return;
				}

				if (!pushDeliveryTokenRef.current?.token.trim().length) {
					logLiveActivitySubscription("retrying push delivery token on foreground");
					void syncPushDeliveryToken("foreground retry");
					return;
				}

				logLiveActivitySubscription("retrying live activity subscriptions on foreground");
				flushLiveActivitySubscriptionsRef.current();
			});

			return () => {
				canceled = true;
				unsubscribe();
				appStateSubscription.remove();
			};
		}, [flushLiveActivitySubscriptions]);

	useEffect(() => {
		return () => {
			clearLiveActivitySubscriptionRetry();
		};
	}, [clearLiveActivitySubscriptionRetry]);

	useEffect(() => {
		const unsubscribe = subscribeThreadLiveActivityPushToken((event) => {
			const normalizedPushToken = event.pushToken.trim();
			if (normalizedPushToken.length === 0) {
				logLiveActivitySubscription("live activity token event ignored", {
					chatId: event.chatId,
				});
				return;
			}

			liveActivityTokenByChatRef.current[event.chatId] = normalizedPushToken;
			logLiveActivitySubscription("live activity token received", {
				chatId: event.chatId,
				liveActivityToken: toTokenPreview(normalizedPushToken),
			});
			flushLiveActivitySubscriptions();
		});

		return () => {
			unsubscribe();
		};
	}, [flushLiveActivitySubscriptions]);

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
					structuredLiveActivityPreviewByChatRef.current[chatId] = true;

					let latestTurn = queryClient.getQueryData<StreamTurnState | null>(queryKeys.streamTurn(chatId)) ?? null;
				for (const entry of events) {
					latestTurn = applyAssistantEventToTurn(latestTurn, entry.event);
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
				const isBackgroundAppState = appStateRef.current === "background" || appStateRef.current === "inactive";
				const latestEvent = events.at(-1)?.event;
				const latestStatusLine = latestEvent ? toLiveActivityStatusLineFromEvent(latestEvent) : undefined;
				updateRunningLiveActivity({
					authoritative: true,
					chatId,
					phase: isBackgroundAppState ? "background" : "running",
					preview: latestEvent && latestTurn ? toLiveActivityPreviewFromTurn(latestTurn, latestEvent) : undefined,
					statusLine: latestStatusLine,
				});
			} catch {
				void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
			}
		},
		[client, queryClient, updateRunningLiveActivity],
	);

	const handleServerEvent = useCallback(
		(event: ServerWsEvent) => {
			const isBackgroundAppState = appStateRef.current === "background" || appStateRef.current === "inactive";

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
					const prefersStructuredLiveActivityPreview = structuredLiveActivityPreviewByChatRef.current[chatId];
					setStreamingTextByChat((current) => ({
						...current,
						[chatId]: (() => {
							const nextPreview = `${current[chatId] ?? ""}${event.data.delta}`;
							if (!prefersStructuredLiveActivityPreview) {
								updateRunningLiveActivity({
									authoritative: true,
									chatId,
									phase: isBackgroundAppState ? "background" : "running",
									preview: nextPreview,
									statusLine: isBackgroundAppState ? "Running in background" : "Generating response",
								});
							}
							return nextPreview;
						})(),
					}));
					clearSendingForChat(chatId);
					return;
				}

				if (event.event === "assistant_snapshot") {
					const prefersStructuredLiveActivityPreview = structuredLiveActivityPreviewByChatRef.current[event.data.chatId];
					setStreamingTextByChat((current) => ({
						...current,
						[event.data.chatId]: event.data.partialText,
					}));
					if (!prefersStructuredLiveActivityPreview) {
						updateRunningLiveActivity({
							authoritative: true,
							chatId: event.data.chatId,
							phase: isBackgroundAppState ? "background" : "running",
							preview: event.data.partialText,
							statusLine: isBackgroundAppState ? "Running in background" : "Generating response",
						});
					}
					return;
				}

				if (event.event === "assistant_event") {
					const incomingEventId = event.data.eventId;
					const chatId = event.data.chatId;
					structuredLiveActivityPreviewByChatRef.current[chatId] = true;
					const lastAppliedEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
					if (typeof incomingEventId === "number" && incomingEventId <= lastAppliedEventId) {
						return;
					}
					if (typeof incomingEventId === "number") {
						lastAssistantEventIdByChatRef.current[chatId] = incomingEventId;
					}

					const nextTurn = applyAssistantEventToTurn(
						queryClient.getQueryData<StreamTurnState | null>(queryKeys.streamTurn(chatId)) ?? null,
						event.data.event,
					);
					queryClient.setQueryData<StreamTurnState | null>(
						queryKeys.streamTurn(chatId),
						nextTurn,
					);

				setStreamHistoryByChat((current) => {
					const nextHistory = applyAssistantEventToHistory(current[chatId], event.data.event);
					return {
						...current,
						[chatId]: nextHistory,
					};
				});
				const statusLine = toLiveActivityStatusLineFromEvent(event.data.event);
				const activityPhase: "running" | "background" | "finalizing" = (() => {
					if (event.data.event.type === "turn_completed") {
						return "finalizing";
					}
					if (isBackgroundAppState) {
						return "background";
					}
					return "running";
				})();
				const toFallbackStatusLine = (phase: "running" | "background" | "finalizing"): string | undefined => {
					if (phase === "background") {
						return "Running in background";
					}
					if (phase === "finalizing") {
						return "Finalizing response";
					}
					return undefined;
				};
				const activityStatusLine = statusLine ?? toFallbackStatusLine(activityPhase);
				updateRunningLiveActivity({
					authoritative: true,
					chatId,
					phase: activityPhase,
					preview: toLiveActivityPreviewFromTurn(nextTurn, event.data.event),
					statusLine: activityStatusLine,
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
				const previousChatStatus = queryClient.getQueryData<ChatContextDTO>(queryKeys.chatContext(event.data.chatId))?.chat.status ?? null;
					invalidateWorkspaceQuery(queryKeys.activeThreads);
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
									isActive: event.data.isActive,
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
					if (event.data.status === "running" && shouldTrackLiveActivity && previousChatStatus !== "running") {
						clearStructuredLiveActivityPreview(event.data.chatId);
						const runningStatus = isBackgroundAppState ? "Running in background" : "Running";
						startRunningLiveActivity(event.data.chatId, {
							statusLine: runningStatus,
						});
					if (isBackgroundAppState) {
						updateRunningLiveActivity({
							chatId: event.data.chatId,
							phase: "background",
							statusLine: runningStatus,
						});
					}
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
						invalidateWorkspaceQuery(queryKeys.activeThreads);
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
						// Keep selection local on mobile to prevent cross-client navigation jumps.
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
				clearStructuredLiveActivityPreview,
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

		void onThreadLiveActivityAppStateChanged(appStateRef.current);

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
						if (events.length > 0) {
							structuredLiveActivityPreviewByChatRef.current[selectedChatId] = true;
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
			queryClient.setQueryData(queryKeys.selection, nextSelection);

			updateSelectionMutation.mutate(nextSelection, {
				onError: () => {
					void queryClient.invalidateQueries({ queryKey: queryKeys.selection });
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

	const selectProjectById = useCallback(
		(projectId: string | null) => {
			setSelectedProjectId(projectId);
			setSelectedChatId(null);
			setLastError(null);
			if (projectId) {
				void queryClient.invalidateQueries({
					queryKey: queryKeys.chats(projectId),
				});
			}

			persistSelection({
				selectedChatId: null,
				selectedProjectId: projectId,
			});
		},
		[persistSelection, queryClient],
	);

	const selectProject = useCallback(
		(project: ProjectDTO) => {
			selectProjectById(project.id);
		},
		[selectProjectById],
	);

	const selectChatById = useCallback(
		(input: { chatId: string; projectId: string | null }) => {
			const normalizedChatId = input.chatId.trim();
			if (normalizedChatId.length === 0) {
				return;
			}

			const normalizedProjectId = input.projectId?.trim() ?? "";
			const nextProjectId = normalizedProjectId.length > 0 ? normalizedProjectId : selectedProjectIdRef.current;
			if (!nextProjectId) {
				return;
			}
			setSelectedProjectId(nextProjectId ?? null);
			setSelectedChatId(normalizedChatId);
			setLastError(null);

			persistSelection({
				selectedChatId: normalizedChatId,
				selectedProjectId: nextProjectId,
			});

			realtimeRef.current?.sendJoinChat(normalizedChatId);
		},
		[persistSelection],
	);

	const selectChat = useCallback(
		(chat: ChatDTO) => {
			selectChatById({
				chatId: chat.id,
				projectId: chat.projectId,
			});
		},
		[selectChatById],
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
			clearLiveActivitySubscriptionState(chatId);
			await clearThreadLiveActivity({
				chatId,
			});

			if (selectedChatId === chatId) {
				setSelectedChatId(null);
				persistSelection({
					selectedChatId: null,
					selectedProjectId,
				});
			}
		},
		[clearLiveActivitySubscriptionState, deleteChatMutation, persistSelection, selectedChatId, selectedProjectId],
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

			selectChatById({
				chatId: chat.id,
				projectId: selectedProjectId,
			});
			return chat;
		},
		[createChatMutation, selectedProjectId, selectChatById],
	);

	const createProject = useCallback(
		async (input: { name?: string; path: string }) => {
			const project = await client.createProject(input);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });

			selectProjectById(project.id);

			return project;
		},
		[client, queryClient, selectProjectById],
	);

	const deleteProject = useCallback(
		async (projectId: string) => {
			await client.deleteProject(projectId);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });

			if (selectedProjectId === projectId) {
				setSelectedProjectId(null);
				setSelectedChatId(null);
				persistSelection({
					selectedChatId: null,
					selectedProjectId: null,
				});
			}
			if (selectedChatIdRef.current) {
				clearLiveActivitySubscriptionState(selectedChatIdRef.current);
				await clearThreadLiveActivity({
					chatId: selectedChatIdRef.current,
				});
			}
		},
		[clearLiveActivitySubscriptionState, client, persistSelection, queryClient, selectedProjectId],
	);

	const renameProject = useCallback(
		async (projectId: string, name: string) => {
			const normalizedName = name.trim();
			if (normalizedName.length === 0) {
				throw new Error("Workspace name cannot be empty.");
			}

			await client.renameProject(projectId, normalizedName);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });
		},
		[client, queryClient],
	);

	const sendMessage = useMutation({
		mutationFn: async (rawText: string) => {
			const text = rawText.trim();
			lastSendAttemptChatIdRef.current = null;

			const activeProjectId = selectedProjectIdRef.current;
			if (!activeProjectId || text.length === 0) {
				return false;
			}

			const activeSelectedChatId = selectedChatIdRef.current;
			const selectedChatFromList = chats.find((chat) => chat.id === activeSelectedChatId) ?? null;
			const selectedChatFromContext = activeSelectedChatId
				? queryClient.getQueryData<ChatContextDTO>(queryKeys.chatContext(activeSelectedChatId))?.chat ?? null
				: null;
			const selectedChat = selectedChatFromList ?? selectedChatFromContext;
			const isSelectedChatActiveFromThreadList = Boolean(
				activeSelectedChatId &&
				(activeThreadsQuery.data ?? []).some((thread) => thread.id === activeSelectedChatId),
			);
			if (selectedChat?.isActive || isSelectedChatActiveFromThreadList) {
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
				replacementChat || selectedChat ? null : await createChat(text);
			const activeChatId =
				replacementChat?.id ??
				selectedChat?.id ??
				fallbackChat?.id ??
				null;

			if (!activeChatId) {
				return false;
			}
			lastSendAttemptChatIdRef.current = activeChatId;

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
				invalidateWorkspaceQuery(queryKeys.activeThreads);
				if (!isThreadLiveActivityEnabled()) {
					void ensureLocalNotificationPermission();
				}
				clearStructuredLiveActivityPreview(activeChatId);
				startRunningLiveActivity(activeChatId, {
					chatTitle: replacementChat?.title ?? selectedChat?.title ?? fallbackChat?.title,
					restart: true,
					statusLine: "Running",
				});

			realtimeRef.current?.sendJoinChat(activeChatId);
			realtimeRef.current?.sendUserMessage(activeChatId, text, {
				clientId: clientIdRef.current,
				model: selectedModel ?? undefined,
				permissionMode,
				projectId: activeProjectId,
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
			const selected = lastSendAttemptChatIdRef.current ?? selectedChatIdRef.current;
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
		onSettled: () => {
			lastSendAttemptChatIdRef.current = null;
		},
	});

	const forceStopActiveChat = useCallback(async (): Promise<boolean> => {
		const chatId = selectedChatIdRef.current;
		if (!chatId) {
			return false;
		}

		setStoppingByChat((current) => ({
			...current,
			[chatId]: true,
		}));

		try {
			const result = await client.stopChat(chatId);
			const activeProjectId = selectedProjectIdRef.current;
			const stoppedChat = result.chat;

			if (stoppedChat) {
				queryClient.setQueryData<ChatContextDTO>(
					queryKeys.chatContext(chatId),
					(current) => (
						current
							? {
								...current,
								chat: {
									...current.chat,
									diffAdded: stoppedChat.diffAdded,
									diffRemoved: stoppedChat.diffRemoved,
									isActive: stoppedChat.isActive,
									status: stoppedChat.status,
									title: stoppedChat.title,
									updatedAt: stoppedChat.updatedAt,
								},
							}
							: current
					),
				);

				if (activeProjectId) {
					queryClient.setQueryData<(ChatDTO | { id: string; isActive?: boolean; title: string; updatedAt: string })[]>(
						queryKeys.chats(activeProjectId),
						(current) => {
							if (!Array.isArray(current)) {
								return current;
							}

							return current.map((chat) => {
								if (chat.id !== chatId) {
									return chat;
								}

								if ("projectId" in chat) {
									return {
										...chat,
										diffAdded: stoppedChat.diffAdded,
										diffRemoved: stoppedChat.diffRemoved,
										isActive: stoppedChat.isActive,
										status: stoppedChat.status,
										title: stoppedChat.title,
										updatedAt: stoppedChat.updatedAt,
									};
								}

								return {
									...chat,
									isActive: stoppedChat.isActive,
									title: stoppedChat.title,
									updatedAt: stoppedChat.updatedAt,
								};
							});
						},
					);
				}
			}

			if (result.stopped) {
				queryClient.setQueryData<ActiveThreadSummaryDTO[]>(
					queryKeys.activeThreads,
					(current) => Array.isArray(current) ? current.filter((thread) => thread.id !== chatId) : current,
				);
				queryClient.setQueryData(queryKeys.streamTurn(chatId), null);
				setStreamingTextByChat((current) => ({
					...current,
					[chatId]: "",
				}));
				pendingSendChatIdsRef.current.delete(chatId);
				setSendingByChat((current) => ({
					...current,
					[chatId]: false,
				}));
				pendingCompletionNotificationChatIdsRef.current.delete(chatId);
				finishLiveActivity(chatId, {
					outcome: "error",
				});
				setLastError(null);
				invalidateWorkspaceQuery(queryKeys.activeThreads);
				if (activeProjectId && shouldEnableChatsQuery) {
					invalidateWorkspaceQuery(queryKeys.chats(activeProjectId));
				}
				invalidateWorkspaceQuery(queryKeys.chatContext(chatId));
				return true;
			}

			setLastError("This thread is no longer running.");
			return false;
		} catch (error) {
			setLastError(error instanceof Error ? error.message : "Failed to stop thread");
			return false;
			} finally {
				setStoppingByChat((current) => {
					if (!current[chatId]) {
						return current;
					}

					const { [chatId]: ignore, ...next } = current;
					void ignore;
					return next;
				});
			}
		}, [
		client,
		finishLiveActivity,
		invalidateWorkspaceQuery,
		queryClient,
		shouldEnableChatsQuery,
	]);

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
	const isStopping = selectedChatId ? Boolean(stoppingByChat[selectedChatId]) : false;
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
	const hasSelectionSnapshot = selectionQuery.data !== undefined || selectionQuery.isFetched;
	const activeThreads = activeThreadsQuery.data ?? [];
	const isActiveThreadsLoading = activeThreadsQuery.isPending && activeThreads.length === 0;

	return {
		activeThreads,
		availableModels: modelsQuery.data?.models ?? [],
		chatsErrorMessage,
		chats,
		connectionState,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		hasOlderMessages: shouldEnableMessagesQuery ? messagesQuery.hasOlderMessages : false,
		isLoaded: !isProjectsLoading && hasSelectionSnapshot,
		isLoadingOlderMessages: shouldEnableMessagesQuery ? messagesQuery.isLoadingOlderMessages : false,
		isChatsLoading,
		isMessagesLoading,
		isActiveThreadsLoading,
		isSending,
		isStopping,
		lastError,
		loadOlderMessages: shouldEnableMessagesQuery ? messagesQuery.loadOlderMessages : async () => undefined,
		messages,
		permissionMode,
		projects,
		renameProject,
		selectedModel,
		selectedReasoningEffort,
		selectChat,
		selectChatById,
		selectProject,
		selectProjectById,
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
		forceStopActiveChat,
		streamHistoryTurns,
		streamingText,
		streamingTurn: streamTurnQuery.data ?? null,
		toggleFavorite,
	};
};
