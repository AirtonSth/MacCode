import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { useChatsQuery } from "@/features/chat/api/use-chats-query";
import { useCreateChatMutation } from "@/features/chat/api/use-create-chat-mutation";
import { useDeleteChatMutation } from "@/features/chat/api/use-delete-chat-mutation";
import { useMessagesQuery } from "@/features/chat/api/use-messages-query";
import { useUpdateWorkspaceSelectionMutation } from "@/features/settings/api/use-update-workspace-selection-mutation";
import { useWorkspaceSelectionQuery } from "@/features/settings/api/use-workspace-selection-query";
import { useProjectsQuery } from "@/features/threads/api/use-projects-query";
import { useToggleFavoriteMutation } from "@/features/threads/api/use-toggle-favorite-mutation";
import { useApiConfig } from "@/shared/api/api-config-provider";
import { queryKeys } from "@/shared/api/query-keys";
import type { ChatDTO, MessageDTO, ProjectDTO, ServerWsEvent } from "@/shared/api/types";
import { createRealtimeClient, type ConnectionState } from "@/shared/api/ws-client";

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

export const useWorkspaceShell = () => {
	const queryClient = useQueryClient();
	const { config } = useApiConfig();
	const createChatMutation = useCreateChatMutation();
	const updateSelectionMutation = useUpdateWorkspaceSelectionMutation();
	const [lastError, setLastError] = useState<string | null>(null);
	const [isSending, setIsSending] = useState<boolean>(false);
	const [connectionState, setConnectionState] = useState<ConnectionState>("idle");
	const [selectedProjectId, setSelectedProjectId] = useState<string | null>(null);
	const [selectedChatId, setSelectedChatId] = useState<string | null>(null);
	const realtimeRef = useRef<ReturnType<typeof createRealtimeClient> | null>(null);
	const hasBootstrappedSelectionRef = useRef<boolean>(false);
	const projectsQuery = useProjectsQuery();
	const chatsQuery = useChatsQuery(selectedProjectId);
	const messagesQuery = useMessagesQuery(selectedChatId);
	const selectionQuery = useWorkspaceSelectionQuery();
	const toggleFavoriteMutation = useToggleFavoriteMutation();
	const deleteChatMutation = useDeleteChatMutation(selectedProjectId);

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

		setSelectedProjectId(selectionQuery.data.selectedProjectId);
		setSelectedChatId(selectionQuery.data.selectedChatId);
		hasBootstrappedSelectionRef.current = true;
	}, [selectionQuery.data]);

	useEffect(() => {
		if (!hasBootstrappedSelectionRef.current) {
			return;
		}

		if (selectedProjectId || !projectsQuery.data || projectsQuery.data.length === 0) {
			return;
		}

		const fallbackProject = projectsQuery.data[0];
		setSelectedProjectId(fallbackProject.id);
		setSelectedChatId(null);
		updateSelectionMutation.mutate({
			selectedChatId: null,
			selectedProjectId: fallbackProject.id,
		});
	}, [projectsQuery.data, selectedProjectId, updateSelectionMutation]);

	useEffect(() => {
		if (!selectedProjectId || !chatsQuery.data || chatsQuery.data.length === 0 || selectedChatId) {
			return;
		}

		const fallbackChat = chatsQuery.data[0];
		setSelectedChatId(fallbackChat.id);
		updateSelectionMutation.mutate({
			selectedChatId: fallbackChat.id,
			selectedProjectId,
		});
	}, [chatsQuery.data, selectedChatId, selectedProjectId, updateSelectionMutation]);

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
			}
		},
		[queryClient, selectedProjectId],
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

	const selectProject = useCallback(
		(project: ProjectDTO) => {
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
			realtimeRef.current?.sendUserMessage(activeChatId, text);

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
		chats: chatsQuery.data ?? [],
		connectionState,
		createChat,
		deleteChat,
		isLoaded: !projectsQuery.isLoading && selectionQuery.isFetched,
		isSending,
		lastError,
		messages: messagesQuery.data ?? [],
		projects: projectsQuery.data ?? [],
		selectChat,
		selectProject,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage: sendMessage.mutateAsync,
		streamingText: streamingTextQuery.data ?? "",
		toggleFavorite,
	};
};
