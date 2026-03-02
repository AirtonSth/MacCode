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
import type { ChatDTO, MessageDTO, ProjectDTO, ServerWsEvent } from "../../../shared/api/types";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";

const appendAssistantMessage = (
	messages: MessageDTO[],
	chatId: string,
	content: string,
): MessageDTO[] => {
	const trimmed = content.trim();

	if (trimmed.length === 0) {
		return messages;
	}

	const lastMessage = messages[messages.length - 1];
	if (lastMessage && lastMessage.role === "assistant" && lastMessage.content === trimmed) {
		return messages;
	}

	return [
		...messages,
		{
			chatId,
			content: trimmed,
			createdAt: new Date().toISOString(),
			id: `assistant-${Date.now()}`,
			role: "assistant",
		},
	];
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

const toRequestId = (): string =>
	`req-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`;

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

	useQuery({
		gcTime: Number.POSITIVE_INFINITY,
		initialData: [],
		queryFn: async () => [],
		queryKey: queryKeys.streamEvents(selectedChatId),
		staleTime: Number.POSITIVE_INFINITY,
	});

	const streamingTextQuery = useQuery({
		gcTime: Number.POSITIVE_INFINITY,
		initialData: "",
		queryFn: async () => "",
		queryKey: queryKeys.streamingText(selectedChatId),
		staleTime: Number.POSITIVE_INFINITY,
	});

	useEffect(() => {
		if (!selectionQuery.data || hasBootstrappedSelectionRef.current) {
			return;
		}

		inMemorySelectedProjectId = selectionQuery.data.selectedProjectId;
		inMemorySelectedChatId = selectionQuery.data.selectedChatId;
		setSelectedProjectId(inMemorySelectedProjectId);
		setSelectedChatId(inMemorySelectedChatId);
		hasBootstrappedSelectionRef.current = true;
	}, [selectionQuery.data]);

	const handleServerEvent = useCallback(
		(event: ServerWsEvent) => {
			if (event.event === "assistant_delta") {
				queryClient.setQueryData<string>(
					queryKeys.streamingText(event.data.chatId),
					(current) => `${current ?? ""}${event.data.delta}`,
				);
				return;
			}

				if (event.event === "assistant_event") {
					const assistantEvent = event.data.event;

					queryClient.setQueryData(
						queryKeys.streamEvents(event.data.chatId),
						(current: unknown) => {
							const list = Array.isArray(current) ? current : [];
							return [...list, assistantEvent];
						},
					);

					if (assistantEvent.type === "item_delta" && assistantEvent.target === "body") {
						queryClient.setQueryData<string>(
							queryKeys.streamingText(event.data.chatId),
							(current) => `${current ?? ""}${assistantEvent.delta}`,
						);
					}

				return;
			}

			if (event.event === "assistant_done") {
				const streamingText = queryClient.getQueryData<string>(queryKeys.streamingText(event.data.chatId)) ?? "";
				queryClient.setQueryData<MessageDTO[]>(
					queryKeys.messages(event.data.chatId),
					(current) => appendAssistantMessage(current ?? [], event.data.chatId, streamingText),
				);
				queryClient.setQueryData(queryKeys.streamingText(event.data.chatId), "");
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

	const selectProject = useCallback(
		(project: ProjectDTO) => {
			inMemorySelectedProjectId = project.id;
			inMemorySelectedChatId = null;
			setSelectedProjectId(project.id);
			setSelectedChatId(null);
			setLastError(null);

			updateSelectionMutation.mutate({
				selectedChatId: null,
				selectedProjectId: project.id,
			});
		},
		[updateSelectionMutation],
	);

	const selectChat = useCallback(
		(chat: ChatDTO) => {
			inMemorySelectedProjectId = chat.projectId;
			inMemorySelectedChatId = chat.id;
			setSelectedProjectId(chat.projectId);
			setSelectedChatId(chat.id);
			setLastError(null);

			updateSelectionMutation.mutate({
				selectedChatId: chat.id,
				selectedProjectId: chat.projectId,
			});

			realtimeRef.current?.sendJoinChat(chat.id);
		},
		[updateSelectionMutation],
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
				updateSelectionMutation.mutate({
					selectedChatId: null,
					selectedProjectId,
				});
			}
		},
		[deleteChatMutation, selectedChatId, selectedProjectId, updateSelectionMutation],
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
			updateSelectionMutation.mutate({
				selectedChatId: chat.id,
				selectedProjectId,
			});
			realtimeRef.current?.sendJoinChat(chat.id);

			return chat;
		},
		[createChatMutation, selectedProjectId, updateSelectionMutation],
	);

	const createProject = useCallback(
		async (input: { name?: string; path: string }) => {
			const project = await client.createProject(input);
			await queryClient.invalidateQueries({ queryKey: queryKeys.projects });

			inMemorySelectedProjectId = project.id;
			inMemorySelectedChatId = null;
			setSelectedProjectId(project.id);
			setSelectedChatId(null);
			updateSelectionMutation.mutate({
				selectedChatId: null,
				selectedProjectId: project.id,
			});

			return project;
		},
		[client, queryClient, updateSelectionMutation],
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
				updateSelectionMutation.mutate({
					selectedChatId: null,
					selectedProjectId: null,
				});
			}
		},
		[client, queryClient, selectedProjectId, updateSelectionMutation],
	);

	const sendMessage = useMutation({
		mutationFn: async (rawText: string) => {
			const text = rawText.trim();

			if (!selectedProjectId || text.length === 0) {
				return false;
			}

			let activeChatId = selectedChatId;

			if (!activeChatId) {
				const chat = await createChat("New thread");
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
			queryClient.setQueryData(queryKeys.streamingText(activeChatId), "");
			queryClient.setQueryData(queryKeys.streamEvents(activeChatId), []);
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

			return true;
		},
		onError: (error: unknown) => {
			setIsSending(false);
			setLastError(error instanceof Error ? error.message : "Failed to send message");
		},
	});

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
		setPermissionMode,
		setSelectedModel,
		setSelectedReasoningEffort,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage: sendMessage.mutateAsync,
		streamingText: streamingTextQuery.data ?? "",
		toggleFavorite,
	};
};
