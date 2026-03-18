import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AppState, Platform, type AppStateStatus } from "react-native";

import { useChatsQuery } from "../api/use-chats-query";
import { useChatContextQuery } from "../api/use-chat-context-query";
import { useCreateChatMutation } from "../api/use-create-chat-mutation";
import { useDeleteChatMutation } from "../api/use-delete-chat-mutation";
import {
	appendMessageToMessagePage,
	MESSAGE_PAGE_SIZE,
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
	hasActiveLiveActivityEntry,
	setThreadLiveActivityRemoteManaged,
	isThreadLiveActivityEnabled,
	onThreadLiveActivityAppStateChanged,
	startThreadLiveActivity,
	subscribeThreadLiveActivityPushToken,
	updateThreadLiveActivity,
	getPushToStartToken,
	subscribePushToStartToken,
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
	mapChatTurnsToStreamTurns,
	setStreamItemExpanded as updateStreamItemExpanded,
	setStreamItemState as updateStreamItemState,
	type StreamTurnState,
} from "./stream-turn-state";
import {
	resolveLiveActivitySubscriptionError,
	resolveLiveActivitySubscriptionResponse,
} from "./live-activity-subscription";
import { resolveTrackedLiveActivityChats } from "./live-activity-tracking";

type WorkspaceShellScope = "legacy" | "workspaces" | "threads" | "chat";

interface UseWorkspaceShellOptions {
	scope?: WorkspaceShellScope;
	shouldLoadDrawerWorkspaces?: boolean;
	isActive?: boolean;
}

type AssistantEventPayload = Extract<ServerWsEvent, { event: "assistant_event" }>["data"]["event"];

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

const resolveLiveActivitySubscriptionTransport = (input: {
	liveActivityToken: string;
	pushDeliveryToken: PushDeliveryToken | null;
}): { pushToken: string; pushTokenType: "apns" | "fcm" } | null => {
	const normalizedLiveActivityToken = input.liveActivityToken.trim();
	if (normalizedLiveActivityToken.length === 0) {
		return null;
	}

	const normalizedPushToken = input.pushDeliveryToken?.token.trim() ?? "";
	const pushTokenType = input.pushDeliveryToken?.type;
	if (normalizedPushToken.length > 0 && (pushTokenType === "apns" || pushTokenType === "fcm")) {
		return {
			pushToken: normalizedPushToken,
			pushTokenType,
		};
	}

	if (Platform.OS === "ios") {
		return {
			pushToken: normalizedLiveActivityToken,
			pushTokenType: "apns",
		};
	}

	return null;
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
	const validProviders = ["codex", "claude"] as const;
	const selectedProvider =
		typeof selection.selectedProvider === "string" && (validProviders as readonly string[]).includes(selection.selectedProvider)
			? selection.selectedProvider
			: null;

	return {
		selectedProjectId,
		selectedChatId,
		permissionMode: normalizePermissionMode(selection.permissionMode),
		selectedModel: normalizeSelectedModel(selection.selectedModel),
		selectedProvider,
		selectedReasoningEffort: normalizeReasoningEffort(selection.selectedReasoningEffort),
	};
};

const DEFAULT_SELECTION: WorkspaceSelectionDTO = {
	permissionMode: "default",
	selectedChatId: null,
	selectedModel: null,
	selectedProjectId: null,
	selectedProvider: null,
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

type ThreadListChatEntry =
	| ChatDTO
	| { id: string; isActive?: boolean; title: string; updatedAt: string };

const sortThreadListChatEntries = <T extends ThreadListChatEntry>(entries: T[]): T[] => (
	Array.from(entries).sort(
		(left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime(),
	)
);

const moveChatToFrontOfThreadList = (
	currentEntries: ThreadListChatEntry[] | undefined,
	nextChat: { id: string; isActive: boolean; title: string; updatedAt: string },
	projectId: string | null,
): ThreadListChatEntry[] | undefined => {
	if (!currentEntries) {
		return currentEntries;
	}

	const existingEntry = currentEntries.find((entry) => entry.id === nextChat.id);
	const updatedEntry: ThreadListChatEntry = (() => {
		if (existingEntry) {
			if ("projectId" in existingEntry) {
				return {
					...existingEntry,
					isActive: nextChat.isActive,
					status: nextChat.isActive ? "running" : existingEntry.status,
					title: nextChat.title,
					updatedAt: nextChat.updatedAt,
				};
			}

			return {
				...existingEntry,
				isActive: nextChat.isActive,
				title: nextChat.title,
				updatedAt: nextChat.updatedAt,
			};
		}

		return projectId ? toChatDtoFromThreadSummary(nextChat, projectId) : nextChat;
	})();

	return sortThreadListChatEntries([
		updatedEntry,
		...currentEntries.filter((entry) => entry.id !== nextChat.id),
	]);
};

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
	const [messageWindowModeByChat, setMessageWindowModeByChat] = useState<Record<string, "latest" | "older">>({});
	const [latestDirtyByChat, setLatestDirtyByChat] = useState<Record<string, boolean>>({});
	const [stoppingByChat, setStoppingByChat] = useState<Record<string, boolean>>({});
	const [permissionMode, setPermissionMode] = useState<string>(initialSelection.permissionMode);
	const [selectedModel, setSelectedModel] = useState<string | null>(initialSelection.selectedModel);
	const [selectedReasoningEffort, setSelectedReasoningEffort] = useState<string | null>(
		initialSelection.selectedReasoningEffort,
	);
	const [selectedProvider, setSelectedProvider] = useState<string>(
		initialSelection.selectedProvider ?? "codex",
	);
	const realtimeRef = useRef<ReturnType<typeof createRealtimeClient> | null>(null);
	const lastWorkspaceSeqRef = useRef<number>(0);
	const selectedProjectIdRef = useRef<string | null>(selectedProjectId);
	const selectedChatIdRef = useRef<string | null>(selectedChatId);
	const previousSelectedChatIdRef = useRef<string | null>(selectedChatId);
	const pendingSendChatIdsRef = useRef<Set<string>>(new Set());
	const pendingCompletionNotificationChatIdsRef = useRef<Set<string>>(new Set());
	const trackedLiveActivityChatIdsRef = useRef<Set<string>>(new Set());
	const lastSendAttemptChatIdRef = useRef<string | null>(null);
	const pushDeliveryTokenRef = useRef<PushDeliveryToken | null>(null);
	const liveActivityTokenByChatRef = useRef<Record<string, string>>({});
	const registeredLiveActivitySignatureByChatRef = useRef<Record<string, string>>({});
	const pendingLiveActivitySignatureByChatRef = useRef<Record<string, string>>({});
	const structuredLiveActivityPreviewByChatRef = useRef<Record<string, true>>({});
	const backgroundStreamPreviewByChatRef = useRef<Record<string, string>>({});
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
	const loadOlderMessages = useCallback(async (): Promise<void> => {
		if (!selectedChatId) {
			return;
		}

		await messagesQuery.loadOlderMessages();
		setMessageWindowModeByChat((current) => ({
			...current,
			[selectedChatId]: "older",
		}));
		queryClient.setQueryData<StreamTurnState | null>(queryKeys.streamTurn(selectedChatId), null);
		setStreamingTextByChat((current) => ({
			...current,
			[selectedChatId]: "",
		}));
	}, [messagesQuery, queryClient, selectedChatId]);
	const loadLatestMessages = useCallback(async (): Promise<void> => {
		if (!selectedChatId) {
			return;
		}

		await messagesQuery.loadLatestMessages();
		setMessageWindowModeByChat((current) => ({
			...current,
			[selectedChatId]: "latest",
		}));
		setLatestDirtyByChat((current) => ({
			...current,
			[selectedChatId]: false,
		}));
	}, [messagesQuery, selectedChatId]);
	const selectionQuery = useWorkspaceSelectionQuery({
		enabled: shouldEnableSelectionQuery,
	});
	const toggleFavoriteMutation = useToggleFavoriteMutation();
	const deleteChatMutation = useDeleteChatMutation(selectedProjectId);
	const modelsQuery = useQuery({
		enabled: shouldEnableModelsQuery,
		queryKey: ["provider-models", selectedProvider],
		queryFn: async () => selectedProvider === "claude"
			? await client.listClaudeModels()
			: await client.listCodexModels(),
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

	const selectedChatIsActive = useMemo(() => {
		return Boolean(chats.find((chat) => chat.id === selectedChatId)?.isActive) ||
			Boolean(chatContextQuery.data?.chat.isActive);
	}, [chatContextQuery.data?.chat.isActive, chats, selectedChatId]);

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
		if (normalizedSelection.selectedProvider) {
			setSelectedProvider((current) => (
				current === normalizedSelection.selectedProvider ? current : (normalizedSelection.selectedProvider ?? current)
			));
		}
	}, [selectionQuery.data]);

	useEffect(() => {
		selectedProjectIdRef.current = selectedProjectId;
	}, [selectedProjectId]);

	useEffect(() => {
		selectedChatIdRef.current = selectedChatId;
	}, [selectedChatId]);

	useEffect(() => {
		const previousChatId = previousSelectedChatIdRef.current;
			if (previousChatId && previousChatId !== selectedChatId) {
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.messages(previousChatId),
				});
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.streamTurn(previousChatId),
				});
				lastAssistantEventIdByChatRef.current = omitRecordKey(
					lastAssistantEventIdByChatRef.current,
					previousChatId,
				);
				structuredLiveActivityPreviewByChatRef.current = omitRecordKey(
					structuredLiveActivityPreviewByChatRef.current,
					previousChatId,
				);
				setStreamingTextByChat((current) => {
					if (!(previousChatId in current)) {
						return current;
				}

				const { [previousChatId]: ignored, ...next } = current;
				void ignored;
				return next;
			});
			setSendingByChat((current) => {
				if (!(previousChatId in current)) {
					return current;
				}

				const { [previousChatId]: ignored, ...next } = current;
				void ignored;
				return next;
			});
			setStoppingByChat((current) => {
				if (!(previousChatId in current)) {
					return current;
				}

				const { [previousChatId]: ignored, ...next } = current;
				void ignored;
				return next;
			});
			setMessageWindowModeByChat((current) => {
				if (!(previousChatId in current)) {
					return current;
				}

				const { [previousChatId]: ignored, ...next } = current;
				void ignored;
				return next;
			});
			setLatestDirtyByChat((current) => {
				if (!(previousChatId in current)) {
					return current;
				}

				const { [previousChatId]: ignored, ...next } = current;
				void ignored;
				return next;
			});
		}

		if (selectedChatId) {
			setMessageWindowModeByChat((current) => ({
				...current,
				[selectedChatId]: current[selectedChatId] ?? "latest",
			}));
			setLatestDirtyByChat((current) => ({
				...current,
				[selectedChatId]: current[selectedChatId] ?? false,
			}));
		}

		previousSelectedChatIdRef.current = selectedChatId;
	}, [queryClient, selectedChatId]);

	const messageWindowModeByRef = useRef(messageWindowModeByChat);
	messageWindowModeByRef.current = messageWindowModeByChat;

	const isViewingLatestMessages = useCallback(
		(chatId: string): boolean => (messageWindowModeByRef.current[chatId] ?? "latest") === "latest",
		[],
	);

	const markLatestMessagesDirty = useCallback((chatId: string) => {
		setLatestDirtyByChat((current) => ({
			...current,
			[chatId]: true,
		}));
	}, []);

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
			async (chatId: string, input?: { chatTitle?: string; statusLine?: string; restart?: boolean }) => {
				const title = input?.chatTitle?.trim() || resolveChatTitle(chatId);

				return await startThreadLiveActivity({
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
			backgroundStreamPreviewByChatRef.current = omitRecordKey(
				backgroundStreamPreviewByChatRef.current,
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
			if (isThreadLiveActivityEnabled() && hasActiveLiveActivityEntry(chatId)) {
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
		for (const [chatId, liveActivityToken] of Object.entries(liveActivityTokenByChatRef.current)) {
			const normalizedLiveActivityToken = liveActivityToken.trim();
			if (normalizedLiveActivityToken.length === 0) {
				logLiveActivitySubscription("flush skipped (missing live activity token)", {
					chatId,
				});
				continue;
			}

			const transport = resolveLiveActivitySubscriptionTransport({
				liveActivityToken: normalizedLiveActivityToken,
				pushDeliveryToken: pushDeliveryTokenRef.current,
			});
			if (!transport) {
				logLiveActivitySubscription("flush skipped (missing subscription transport)", {
					chatId,
					hasPushDeliveryToken: Boolean(pushDeliveryTokenRef.current?.token.trim().length),
				});
				continue;
			}

			const { pushToken, pushTokenType } = transport;
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
					const decision = resolveLiveActivitySubscriptionResponse(result);
					if (decision.kind === "local-only") {
						logLiveActivitySubscription("keeping local live activity after disabled subscription", {
							chatId,
						});
						clearLiveActivitySubscriptionState(chatId);
						void setThreadLiveActivityRemoteManaged({
							chatId,
							remoteManaged: false,
						});
						return;
					}
					if (decision.kind === "retry") {
						logLiveActivitySubscription("subscription not accepted yet; keeping activity and retrying", {
							chatId,
						});
						scheduleLiveActivitySubscriptionRetry({
							chatId,
							reason: decision.reason,
						});
						return;
					}

					const currentLiveActivityToken = liveActivityTokenByChatRef.current[chatId]?.trim() ?? "";
					const currentTransport = resolveLiveActivitySubscriptionTransport({
						liveActivityToken: currentLiveActivityToken,
						pushDeliveryToken: pushDeliveryTokenRef.current,
					});
					if (
						!currentTransport
						|| currentTransport.pushToken !== pushToken
						|| currentTransport.pushTokenType !== pushTokenType
						|| currentLiveActivityToken !== normalizedLiveActivityToken
					) {
						logLiveActivitySubscription("subscription response ignored (stale token state)", {
							chatId,
						});
						return;
					}

					registeredLiveActivitySignatureByChatRef.current[chatId] = signature;
				} catch (error) {
					const decision = resolveLiveActivitySubscriptionError(error);
					if (decision.kind === "clear") {
						logLiveActivitySubscription("clearing live activity after permanent subscription failure", {
							chatId,
							error: error instanceof Error ? error.message : "unknown",
						});
						clearLiveActivitySubscriptionState(chatId);
						void clearThreadLiveActivity({
							chatId,
						});
						return;
					}
					if (decision.kind === "local-only") {
						logLiveActivitySubscription("keeping local live activity after subscription failure", {
							chatId,
							error: error instanceof Error ? error.message : "unknown",
						});
						clearLiveActivitySubscriptionState(chatId);
						void setThreadLiveActivityRemoteManaged({
							chatId,
							remoteManaged: false,
						});
						return;
					}

					logLiveActivitySubscription("subscription request failed", {
						chatId,
						error: error instanceof Error ? error.message : "unknown",
					});
					if (decision.kind !== "retry") {
						return;
					}
					scheduleLiveActivitySubscriptionRetry({
						chatId,
						reason: decision.reason,
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

		const registerPushToStartTokenWithBackend = async (pushToStartToken: string): Promise<void> => {
			const deliveryToken = pushDeliveryTokenRef.current;
			if (!deliveryToken || deliveryToken.token.trim().length === 0) {
				return;
			}
			if (deliveryToken.type !== "apns" && deliveryToken.type !== "fcm") {
				return;
			}
			try {
				await client.registerPushToStartToken({
					pushToStartToken,
					pushToken: deliveryToken.token.trim(),
					pushTokenType: deliveryToken.type,
				});
				logLiveActivitySubscription("push-to-start token registered with backend", {
					pushToStartToken: toTokenPreview(pushToStartToken),
					pushTokenType: deliveryToken.type,
				});
			} catch {
				logLiveActivitySubscription("push-to-start token registration failed");
			}
		};

		const syncPushToStartToken = async (): Promise<void> => {
			const token = await getPushToStartToken();
			if (canceled || !token) {
				return;
			}
			void registerPushToStartTokenWithBackend(token);
		};

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

			// Register push-to-start token immediately once push delivery token is available.
			void syncPushToStartToken();
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

		const unsubscribePushToStart = subscribePushToStartToken((token) => {
			if (canceled) {
				return;
			}
			void registerPushToStartTokenWithBackend(token);
		});

		const unsubscribe = subscribePushDeliveryTokenRefresh((token) => {
			if (canceled) {
				return;
			}

			storePushDeliveryToken(token, "refresh");
			void syncPushToStartToken();
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
			unsubscribePushToStart();
			appStateSubscription.remove();
		};
	}, [client, flushLiveActivitySubscriptions]);

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

	const syncMissedAssistantEventsForChatImpl = useCallback(
		async (chatId: string) => {
			if (!isViewingLatestMessages(chatId)) {
				markLatestMessagesDirty(chatId);
				return;
			}

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
					let appliedAnyEvent = false;
					for (const entry of events) {
						const lastAppliedEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
						if (entry.id <= lastAppliedEventId) {
							continue;
						}

						latestTurn = applyAssistantEventToTurn(latestTurn, entry.event);
						lastAssistantEventIdByChatRef.current[chatId] = entry.id;
						appliedAnyEvent = true;
					}

					if (!appliedAnyEvent) {
						return;
					}

					queryClient.setQueryData<StreamTurnState | null>(
						queryKeys.streamTurn(chatId),
						latestTurn,
					);
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
		[client, isViewingLatestMessages, markLatestMessagesDirty, queryClient, updateRunningLiveActivity],
	);

	const syncMissedAssistantEventsForChatRef = useRef(syncMissedAssistantEventsForChatImpl);
	syncMissedAssistantEventsForChatRef.current = syncMissedAssistantEventsForChatImpl;

	const syncMissedAssistantEventsForChat = useCallback(
		async (chatId: string) => { await syncMissedAssistantEventsForChatRef.current(chatId); },
		[],
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
			const isSelectedChat = (chatId: string): boolean => selectedChatIdRef.current === chatId;

				if (event.event === "assistant_delta") {
					const chatId = event.data.chatId;
					if (!isSelectedChat(chatId)) {
						clearSendingForChat(chatId);
						if (pendingCompletionNotificationChatIdsRef.current.has(chatId)) {
							const currentPreview = backgroundStreamPreviewByChatRef.current[chatId] ?? "";
							const nextPreview = currentPreview + event.data.delta;
							backgroundStreamPreviewByChatRef.current[chatId] = nextPreview;
							updateRunningLiveActivity({
								authoritative: true,
								chatId,
								phase: isBackgroundAppState ? "background" : "running",
								preview: nextPreview,
								statusLine: isBackgroundAppState ? "Running in background" : "Generating response",
							});
						}
						return;
					}
					if (!isViewingLatestMessages(chatId)) {
						markLatestMessagesDirty(chatId);
						clearSendingForChat(chatId);
						return;
					}
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
					if (!isSelectedChat(event.data.chatId)) {
						if (pendingCompletionNotificationChatIdsRef.current.has(event.data.chatId)) {
							backgroundStreamPreviewByChatRef.current[event.data.chatId] = event.data.partialText;
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
					if (!isViewingLatestMessages(event.data.chatId)) {
						markLatestMessagesDirty(event.data.chatId);
						return;
					}
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
					if (!isSelectedChat(chatId)) {
						clearSendingForChat(chatId);
						if (pendingCompletionNotificationChatIdsRef.current.has(chatId)) {
							const statusLine = toLiveActivityStatusLineFromEvent(event.data.event);
							const preview = toLiveActivityPreviewFromEvent(event.data.event);
							updateRunningLiveActivity({
								authoritative: true,
								chatId,
								phase: isBackgroundAppState ? "background" : "running",
								preview,
								statusLine,
							});
						}
						return;
					}
					if (!isViewingLatestMessages(chatId)) {
						markLatestMessagesDirty(chatId);
						clearSendingForChat(chatId);
						return;
					}
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
				if (!isSelectedChat(chatId)) {
					clearSendingForChat(chatId);
					backgroundStreamPreviewByChatRef.current = omitRecordKey(
						backgroundStreamPreviewByChatRef.current,
						chatId,
					);
					finishLiveActivity(chatId, {
						outcome: "completed",
						statusLine: "Response is ready",
					});
					notifyMessageCompletion(chatId, "completed");
					return;
				}
				setStreamingTextByChat((current) => ({
					...current,
					[chatId]: "",
				}));
				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(chatId),
					null,
				);
				clearSendingForChat(chatId);

				void (async () => {
					const maxAttempts = 5;
					const retryDelayMs = 250;
					const trySyncMessages = async (attempt: number): Promise<void> => {
						if (!isViewingLatestMessages(chatId)) {
							markLatestMessagesDirty(chatId);
							return;
						}

						try {
							const latestPage = await client.listMessagesPage(chatId, {
								limit: MESSAGE_PAGE_SIZE,
							});
							if (latestPage.messages.at(-1)?.role === "assistant") {
								queryClient.setQueryData<MessagePageDTO>(
									queryKeys.messages(chatId),
									latestPage,
								);
								setLatestDirtyByChat((current) => ({
									...current,
									[chatId]: false,
								}));
								return;
							}
						} catch {
							// Keep retrying until maxAttempts.
						}

						if (attempt >= maxAttempts) {
							if (isViewingLatestMessages(chatId)) {
								void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
							} else {
								markLatestMessagesDirty(chatId);
							}
							return;
						}

						setTimeout(() => {
							void trySyncMessages(attempt + 1);
						}, retryDelayMs);
					};

					await trySyncMessages(1);
				})();
				invalidateSelectedProjectGitQueries();
				invalidateWorkspaceQuery(queryKeys.chatContext(chatId));
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
				if (!event.data.chatId || selectedChatIdRef.current === event.data.chatId) {
					setLastError(event.data.message);
				}
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
							const currentPage = queryClient.getQueryData<MessagePageDTO>(
								messagesQueryKey,
							);
							if (!currentPage) {
								invalidateWorkspaceQuery(messagesQueryKey);
								break;
							}

							if (isViewingLatestMessages(activeChatId)) {
								queryClient.setQueryData<MessagePageDTO>(
									messagesQueryKey,
									(current) => appendMessageToMessagePage(current, workspaceMessage),
								);
							} else {
								markLatestMessagesDirty(activeChatId);
							}
							break;
						}

						if (isViewingLatestMessages(activeChatId)) {
							invalidateWorkspaceQuery(queryKeys.messages(activeChatId));
						} else {
							markLatestMessagesDirty(activeChatId);
						}
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
				isViewingLatestMessages,
				invalidateSelectedProjectGitQueries,
				invalidateWorkspaceQuery,
				markLatestMessagesDirty,
				notifyMessageCompletion,
				queryClient,
				setSendingByChat,
				shouldEnableChatsQuery,
				startRunningLiveActivity,
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
		for (const trackedChatId of pendingCompletionNotificationChatIdsRef.current) {
			if (trackedChatId !== activeChatId) {
				realtimeRef.current?.sendJoinChat(trackedChatId);
			}
		}
	}, [shouldEnableMessagesQuery]);

	useEffect(function handleWorkspaceRealtimeEffect() {
		if (!isActive) {
			setConnectionState("idle");
			return;
		}

		const realtime = createRealtimeClient({
			onConnectionStateChange: handleConnectionStateChange,
			onEvent: handleServerEvent,
			target: config.activeTarget,
		});

		realtime.connect();
		realtimeRef.current = realtime;

		// eslint-disable-next-line @typescript-eslint/consistent-return
		return () => {
			realtime.disconnect();
			realtimeRef.current = null;
		};
	}, [config.activeTarget, handleConnectionStateChange, handleServerEvent, isActive]);

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
			void queryClient.invalidateQueries({
				queryKey: queryKeys.activeThreads,
			});

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
				queryKey: queryKeys.chatContext(activeChatId),
			});
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
		if (!shouldEnableMessagesQuery || !selectedChatId) {
			return;
		}

		mapChatTurnsToStreamTurns(messagesQuery.page.turns ?? []);
		lastAssistantEventIdByChatRef.current[selectedChatId] = 0;
		queryClient.setQueryData<StreamTurnState | null>(
			queryKeys.streamTurn(selectedChatId),
			null,
		);

		const isViewingLatestWindow = (messageWindowModeByRef.current[selectedChatId] ?? "latest") === "latest";
		if (isViewingLatestWindow && selectedChatIsActive) {
			void syncMissedAssistantEventsForChat(selectedChatId);
		}
	}, [
		messagesQuery.page.turns,
		queryClient,
		selectedChatId,
		selectedChatIsActive,
		shouldEnableMessagesQuery,
		syncMissedAssistantEventsForChat,
	]);

	const persistSelection = useCallback(
		(input: {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode?: string | null;
			selectedModel?: string | null;
			selectedProvider?: string | null;
			selectedReasoningEffort?: string | null;
		}) => {
			const nextSelection = normalizeSelection({
				selectedProjectId: input.selectedProjectId,
				selectedChatId: input.selectedChatId,
				permissionMode: input.permissionMode ?? permissionMode,
				selectedModel: input.selectedModel ?? selectedModel,
				selectedProvider: input.selectedProvider ?? selectedProvider,
				selectedReasoningEffort: input.selectedReasoningEffort ?? selectedReasoningEffort,
			});
			queryClient.setQueryData(queryKeys.selection, nextSelection);

			updateSelectionMutation.mutate(nextSelection, {
				onError: () => {
					void queryClient.invalidateQueries({ queryKey: queryKeys.selection });
				},
			});
		},
		[permissionMode, queryClient, selectedModel, selectedProvider, selectedReasoningEffort, updateSelectionMutation],
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

	const setSelectedProviderWithSync = useCallback(
		(value: string) => {
			setSelectedProvider(value);
			setSelectedModel(null);
			setSelectedReasoningEffort(null);
			void queryClient.invalidateQueries({ queryKey: ["provider-models", value] });
			persistSelection({
				selectedProjectId,
				selectedChatId,
				selectedProvider: value,
				selectedModel: null,
				selectedReasoningEffort: null,
			});
		},
		[persistSelection, queryClient, selectedChatId, selectedProjectId],
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
				provider: selectedProvider,
			});

			selectChatById({
				chatId: chat.id,
				projectId: selectedProjectId,
			});
			return chat;
		},
		[createChatMutation, selectedProjectId, selectedProvider, selectChatById],
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

	const clearAllProjectChats = useCallback(
		async (projectId: string) => {
			const normalizedProjectId = projectId.trim();
			if (!normalizedProjectId) {
				return;
			}

			const threads = await client.listThreadSummaries(normalizedProjectId);
			const threadIds = threads.map((thread) => thread.id).filter((threadId) => threadId.trim().length > 0);
			let clearError: unknown = null;
			const deleteResults = await Promise.allSettled(threads.map(async (thread) => { await deleteChat(thread.id); }));

			for (const deleteResult of deleteResults) {
				if (deleteResult.status === "rejected") {
					const error = deleteResult.reason;
					if (!(error instanceof RemoteCodeRequestError && error.status === 404)) {
						clearError = error;
					}
				}
			}

			await queryClient.invalidateQueries({
				queryKey: queryKeys.chats(normalizedProjectId),
			});
			threadIds.forEach((threadId) => {
				queryClient.removeQueries({ queryKey: queryKeys.chatContext(threadId) });
				queryClient.removeQueries({ queryKey: queryKeys.messages(threadId) });
				queryClient.removeQueries({ queryKey: queryKeys.streamTurn(threadId) });
			});

			if (clearError) {
				throw clearError;
			}

			if (selectedProjectIdRef.current === normalizedProjectId) {
				setSelectedChatId(null);
				persistSelection({
					selectedChatId: null,
					selectedProjectId: normalizedProjectId,
				});
			}
		},
		[
			client,
			deleteChat,
			persistSelection,
			queryClient,
		],
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
			if (activeSelectedChatId && !isViewingLatestMessages(activeSelectedChatId)) {
				await loadLatestMessages();
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

			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(activeChatId),
				(current) => appendMessageToMessagePage(current, nextMessage),
			);
			queryClient.setQueryData<ThreadListChatEntry[]>(
				queryKeys.chats(activeProjectId),
				(current) => moveChatToFrontOfThreadList(
					current,
					{
						id: activeChatId,
						isActive: false,
						title: replacementChat?.title ?? selectedChat?.title ?? fallbackChat?.title ?? "New Thread",
						updatedAt: nextMessage.createdAt,
					},
					activeProjectId,
				),
			);
			setMessageWindowModeByChat((current) => ({
				...current,
				[activeChatId]: "latest",
			}));
			setLatestDirtyByChat((current) => ({
				...current,
				[activeChatId]: false,
			}));
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
					clearStructuredLiveActivityPreview(activeChatId);
					const liveActivityStarted = await startRunningLiveActivity(activeChatId, {
						chatTitle: replacementChat?.title ?? selectedChat?.title ?? fallbackChat?.title,
						statusLine: "Running",
					});
					if (!liveActivityStarted) {
						void ensureLocalNotificationPermission();
					}

			realtimeRef.current?.sendJoinChat(activeChatId);
			realtimeRef.current?.sendUserMessage(activeChatId, text, {
				clientId: clientIdRef.current,
				model: selectedModel ?? undefined,
				permissionMode,
				projectId: activeProjectId,
				provider: selectedProvider ?? undefined,
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
			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(selectedChatId),
				(current) => (
					current
						? {
							...current,
							turns: current.turns.map((turn) => (
								turn.itemsById[itemId]
									? updateStreamItemExpanded(turn as StreamTurnState, itemId, {
										expanded,
										byUser,
									})
									: turn
							)),
						}
						: current
				),
			);
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
			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(selectedChatId),
				(current) => (
					current
						? {
							...current,
							turns: current.turns.map((turn) => (
								turn.itemsById[itemId]
									? updateStreamItemState(turn as StreamTurnState, itemId, state)
									: turn
							)),
						}
						: current
				),
			);
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
	const trackedLiveActivityChats = useMemo(
		() => resolveTrackedLiveActivityChats({
			activeThreads: activeThreadsQuery.data ?? [],
			selectedChat,
			selectedChatId,
		}),
		[activeThreadsQuery.data, selectedChat, selectedChatId],
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

	useEffect(() => {
		if (trackedLiveActivityChats.length === 0) {
			trackedLiveActivityChatIdsRef.current = new Set();
			return;
		}

		const runningStatus =
			appStateRef.current === "background" || appStateRef.current === "inactive"
				? "Running in background"
				: "Running";
		const previousTrackedChatIds = trackedLiveActivityChatIdsRef.current;

		for (const trackedChat of trackedLiveActivityChats) {
			pendingCompletionNotificationChatIdsRef.current.add(trackedChat.chatId);
			realtimeRef.current?.sendJoinChat(trackedChat.chatId);
			if (previousTrackedChatIds.has(trackedChat.chatId)) {
				continue;
			}

			void startRunningLiveActivity(trackedChat.chatId, {
				chatTitle: trackedChat.chatTitle,
				statusLine: runningStatus,
			});
		}

		trackedLiveActivityChatIdsRef.current = new Set(
			trackedLiveActivityChats.map((trackedChat) => trackedChat.chatId),
		);
	}, [startRunningLiveActivity, trackedLiveActivityChats]);

	const streamingText = selectedChatId ? streamingTextByChat[selectedChatId] ?? "" : "";
	const streamHistoryTurns = useMemo(
		() => mapChatTurnsToStreamTurns(messagesQuery.page.turns ?? []),
		[messagesQuery.page.turns],
	);
	const messageWindowMode = selectedChatId ? messageWindowModeByChat[selectedChatId] ?? "latest" : "latest";
	const latestMessagesDirty = selectedChatId ? latestDirtyByChat[selectedChatId] ?? false : false;
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
			clearProjectChats: clearAllProjectChats,
			clearAllProjectChats,
			hasOlderMessages: shouldEnableMessagesQuery ? messagesQuery.hasOlderMessages : false,
		isLoaded: !isProjectsLoading && hasSelectionSnapshot,
		isLoadingOlderMessages: shouldEnableMessagesQuery ? messagesQuery.isLoadingOlderMessages : false,
		isViewingOlderMessages: messageWindowMode === "older",
		isChatsLoading,
		isMessagesLoading,
		isActiveThreadsLoading,
		isSending,
		isStopping,
		lastError,
		latestMessagesDirty,
		loadLatestMessages: shouldEnableMessagesQuery ? loadLatestMessages : async () => undefined,
		loadOlderMessages: shouldEnableMessagesQuery ? loadOlderMessages : async () => undefined,
		messages,
		permissionMode,
		projects,
		renameProject,
		selectedModel,
		selectedProvider,
		selectedReasoningEffort,
		selectChat,
		selectChatById,
		selectProject,
		selectProjectById,
		setPermissionMode: setPermissionModeWithSync,
		setSelectedModel: setSelectedModelWithSync,
		setSelectedProvider: setSelectedProviderWithSync,
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
