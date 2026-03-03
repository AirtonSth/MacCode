import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { useChatsQuery } from "../api/use-chats-query";
import { useCreateChatMutation } from "../api/use-create-chat-mutation";
import { useDeleteChatMutation } from "../api/use-delete-chat-mutation";
import { useMessagesQuery } from "../api/use-messages-query";
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
	MessageDTO,
	ProjectDTO,
	ServerWsEvent,
} from "../../../shared/api/types";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import {
	applyAssistantEventToTurn,
	setStreamItemExpanded as updateStreamItemExpanded,
	setStreamItemState as updateStreamItemState,
	type StreamTurnState,
} from "./stream-turn-state";

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

let inMemorySelectedProjectId: string | null = null;
let inMemorySelectedChatId: string | null = null;

export const useWorkspaceShell = () => {
	const queryClient = useQueryClient();
	const { config } = useApiConfig();
	const createChatMutation = useCreateChatMutation();
	const updateSelectionMutation = useUpdateWorkspaceSelectionMutation();
	const [lastError, setLastError] = useState<string | null>(null);
	const [isSending, setIsSending] = useState<boolean>(false);
	const [connectionState, setConnectionState] = useState<ConnectionState>("idle");
	const [selectedProjectId, setSelectedProjectId] = useState<string | null>(inMemorySelectedProjectId);
	const [selectedChatId, setSelectedChatId] = useState<string | null>(inMemorySelectedChatId);
	const [permissionMode, setPermissionMode] = useState<string>("default");
	const [selectedModel, setSelectedModel] = useState<string | null>(null);
	const [selectedReasoningEffort, setSelectedReasoningEffort] = useState<string | null>(null);
	const realtimeRef = useRef<ReturnType<typeof createRealtimeClient> | null>(null);
	const lastWorkspaceSeqRef = useRef<number>(0);
	const clientIdRef = useRef<string>(`mobile-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`);
	const hasBootstrappedSelectionRef = useRef<boolean>(false);
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

		inMemorySelectedProjectId = selectionQuery.data.selectedProjectId;
		inMemorySelectedChatId = selectionQuery.data.selectedChatId;
		setSelectedProjectId(selectionQuery.data.selectedProjectId);
		setSelectedChatId(selectionQuery.data.selectedChatId);
		setPermissionMode(normalizePermissionMode(selectionQuery.data.permissionMode));
		setSelectedModel(normalizeSelectedModel(selectionQuery.data.selectedModel));
		setSelectedReasoningEffort(normalizeReasoningEffort(selectionQuery.data.selectedReasoningEffort));
		hasBootstrappedSelectionRef.current = true;
	}, [selectionQuery.data]);

	const handleServerEvent = useCallback(
		(event: ServerWsEvent) => {
			if (event.event === "assistant_delta") {
				return;
			}

			if (event.event === "assistant_event") {
				const assistantEvent = event.data.event;
				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(event.data.chatId),
					(current) => applyAssistantEventToTurn(current ?? null, assistantEvent),
				);
				return;
			}

			if (event.event === "assistant_done") {
				queryClient.setQueryData(queryKeys.streamTurn(event.data.chatId), null);
				void queryClient.invalidateQueries({ queryKey: queryKeys.messages(event.data.chatId) });
				setIsSending(false);
				return;
			}

			if (event.event === "chat_updated") {
				queryClient.setQueryData<ChatDTO[]>(
					queryKeys.chats(selectedProjectId),
					(current) => upsertUpdatedChat(current ?? [], event),
				);
				return;
			}

			if (event.event === "error") {
				setLastError(event.data.message);
				if (event.data.chatId) {
					queryClient.setQueryData(queryKeys.streamTurn(event.data.chatId), null);
				}
				setIsSending(false);
				return;
			}

				if (event.event === "workspace_event") {
					lastWorkspaceSeqRef.current = Math.max(lastWorkspaceSeqRef.current, event.data.seq);
					switch (event.data.type) {
						case "chat_created":
						case "chat_deleted":
						case "chat_updated": {
							void queryClient.invalidateQueries({ queryKey: queryKeys.chats(selectedProjectId) });
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
							void queryClient.invalidateQueries({ queryKey: queryKeys.messages(selectedChatId) });
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
		[queryClient, selectedChatId, selectedProjectId],
	);

	useEffect(() => {
		const realtime = createRealtimeClient({
			baseUrl: config.baseUrl,
			onConnectionStateChange: setConnectionState,
			onEvent: handleServerEvent,
			token: config.token,
		});

		realtime.connect();
		realtimeRef.current = realtime;

		return () => {
			realtime.disconnect();
			realtimeRef.current = null;
		};
	}, [config.baseUrl, config.token, handleServerEvent]);

	useEffect(() => {
		if (!selectedChatId || !realtimeRef.current) {
			return;
		}

		realtimeRef.current.sendJoinChat(selectedChatId);
	}, [selectedChatId]);

	useEffect(() => {
		if (!realtimeRef.current) {
			return;
		}

		realtimeRef.current.sendJoinWorkspace(lastWorkspaceSeqRef.current, clientIdRef.current);
	}, [config.baseUrl, config.token]);

	const persistSelection = useCallback(
		(input: {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode?: string | null;
			selectedModel?: string | null;
			selectedReasoningEffort?: string | null;
		}) => {
			const selectedProjectId = input.selectedProjectId;
			const selectedChatId = selectedProjectId ? input.selectedChatId : null;
			updateSelectionMutation.mutate({
				selectedProjectId,
				selectedChatId,
				permissionMode: normalizePermissionMode(input.permissionMode ?? permissionMode),
				selectedModel: normalizeSelectedModel(input.selectedModel ?? selectedModel),
				selectedReasoningEffort: normalizeReasoningEffort(
					input.selectedReasoningEffort ?? selectedReasoningEffort,
				),
			});
		},
		[permissionMode, selectedModel, selectedReasoningEffort, updateSelectionMutation],
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

			let activeChatId = selectedChatId;
			let placeholderChatIdToDelete: string | null = null;

			const selectedChat = chatsQuery.data?.find((chat) => chat.id === selectedChatId) ?? null;
			const selectedChatHasNoMessages = (messagesQuery.data ?? []).length === 0;

			if (
				selectedChat &&
				selectedChatHasNoMessages &&
				isPlaceholderThreadTitle(selectedChat.title)
			) {
				const replacementChat = await createChat(text);
				if (replacementChat) {
					placeholderChatIdToDelete = selectedChat.id;
					activeChatId = replacementChat.id;
				}
			}

			if (!activeChatId) {
				const chat = await createChat(text);
				activeChatId = chat?.id ?? null;
			}

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

			queryClient.setQueryData<MessageDTO[]>(
				queryKeys.messages(activeChatId),
				(current) => [...(current ?? []), nextMessage],
			);
			queryClient.setQueryData(queryKeys.streamTurn(activeChatId), null);
			setLastError(null);
			setIsSending(true);

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
			setIsSending(false);
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

	return {
		availableModels: modelsQuery.data?.models ?? [],
		chats: chatsQuery.data ?? [],
		connectionState,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		isLoaded: !projectsQuery.isLoading && selectionQuery.isFetched,
		isSending,
		lastError,
		messages: messagesQuery.data ?? [],
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
		streamingTurn: streamTurnQuery.data ?? null,
		toggleFavorite,
	};
};
