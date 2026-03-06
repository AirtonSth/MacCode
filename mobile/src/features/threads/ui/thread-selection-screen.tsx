import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useIsFocused } from "@react-navigation/native";
import {
	ActivityIndicator,
	Animated,
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";
import { MaterialIcons } from "@expo/vector-icons";

import { useWorkspaceShell } from "../../chat/model/use-workspace-shell";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { useServerHealthQuery } from "../../../shared/api/use-server-health-query";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { ActiveThreadsFooterCta } from "../../../shared/ui/active-threads-footer-cta";
import { IosActionSheet } from "../../../shared/ui/ios-action-sheet";
import { SwipeableThreadItem } from "./swipeable-thread-item";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

interface ToastPayload {
	message: string;
	type: "error" | "success";
}

export const ThreadSelectionScreen = () => {
	const { goBackOr, push, replace } = useFlowNavigator();
	const { isLoaded: isConfigLoaded } = useApiConfig();
	const isFocused = useIsFocused();
	const {
		activeThreads,
		chats,
		chatsErrorMessage,
		createChat,
		deleteChat,
		isLoaded,
		isActiveThreadsLoading,
		isChatsLoading,
		isMessagesLoading,
		selectChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
	} = useWorkspaceShell({
		isActive: isFocused,
		scope: "threads",
	});
	const [searchValue, setSearchValue] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [openingThreadId, setOpeningThreadId] = useState<string | null>(null);
	const [optimisticDeletedThreadIds, setOptimisticDeletedThreadIds] = useState<Set<string>>(new Set());
	const [toastMessage, setToastMessage] = useState<ToastPayload | null>(null);
	const [threadActionTarget, setThreadActionTarget] = useState<(typeof chats)[number] | null>(null);
	const [errorMessage, setErrorMessage] = useState<string>("");
	const toastOpacity = useRef(new Animated.Value(0)).current;
	const toastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

	const clearThreadToast = useCallback(() => {
		if (toastTimerRef.current) {
			clearTimeout(toastTimerRef.current);
			toastTimerRef.current = null;
		}
	}, []);

	const showThreadToast = useCallback(
		(payload: ToastPayload) => {
			clearThreadToast();
			toastOpacity.stopAnimation();
			setToastMessage(payload);
			toastOpacity.setValue(0);

			Animated.timing(toastOpacity, {
				duration: 140,
				toValue: 1,
				useNativeDriver: true,
			}).start();

			toastTimerRef.current = setTimeout(() => {
				Animated.timing(toastOpacity, {
					duration: 180,
					toValue: 0,
					useNativeDriver: true,
				}).start(() => {
					setToastMessage(null);
				});
			}, 1800);
		},
		[clearThreadToast, toastOpacity],
	);

	useEffect(() => {
		return () => {
			clearThreadToast();
		};
	}, [clearThreadToast]);

	const serverHealthQuery = useServerHealthQuery();

	useEffect(() => {
		if (!isConfigLoaded || !isLoaded || serverHealthQuery.isPending) {
			return;
		}

		if (serverHealthQuery.isError) {
			replace("/settings");
			return;
		}

		if (!selectedProjectId) {
			replace("/workspaces");
		}
	}, [
		isConfigLoaded,
		isLoaded,
		replace,
		selectedProjectId,
		serverHealthQuery.isError,
		serverHealthQuery.isPending,
	]);

	const visibleThreads = useMemo(() => {
		const query = searchValue.trim().toLowerCase();
		const sorted = Array.from(chats).sort(
			(left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime(),
		);

		if (!query) {
			return sorted.filter((chat) => !optimisticDeletedThreadIds.has(chat.id));
		}

		return sorted.filter(
			(chat) => !optimisticDeletedThreadIds.has(chat.id) && chat.title.toLowerCase().includes(query),
		);
	}, [chats, optimisticDeletedThreadIds, searchValue]);
	const activeThreadIds = useMemo(
		() => new Set(activeThreads.map((thread) => thread.id)),
		[activeThreads],
	);
	const selectedProjectActiveThreadsCount = useMemo(
		() => activeThreads.filter((thread) => thread.projectId === selectedProjectId).length,
		[activeThreads, selectedProjectId],
	);
	const shouldShowThreadsLoading = !isLoaded || isChatsLoading;
	const effectiveErrorMessage = errorMessage.length > 0 ? errorMessage : (chatsErrorMessage ?? "");

	useEffect(() => {
		if (!openingThreadId) {
			return;
		}

		if (selectedChatId !== openingThreadId) {
			return;
		}

		if (isMessagesLoading) {
			return;
		}

		setOpeningThreadId(null);
	}, [isMessagesLoading, openingThreadId, selectedChatId]);

	const openThread = (chat: (typeof chats)[number]) => {
		setThreadActionTarget(null);
		setOpeningThreadId(chat.id);
		selectChat(chat);
		push({
			params: {
				source: "thread-list",
			},
			pathname: "/chat",
		});
	};

	const createThread = async () => {
		if (!selectedProjectId) {
			setErrorMessage("Select a workspace first.");
			return;
		}

		setIsCreating(true);
		setErrorMessage("");
		try {
			const newChat = await createChat("New chat");
			if (newChat) {
				push({
					params: {
						source: "thread-list",
					},
					pathname: "/chat",
				});
			}
		} catch (error: unknown) {
			setErrorMessage(error instanceof Error ? error.message : "Failed to create thread.");
		} finally {
			setIsCreating(false);
		}
	};

	const markThreadDeleteOptimistic = useCallback((chatId: string) => {
		setOptimisticDeletedThreadIds((current) => {
			if (current.has(chatId)) {
				return current;
			}

			const next = new Set(current);
			next.add(chatId);
			return next;
		});
	}, []);

	const revertThreadDeletionOptimistic = useCallback((chatId: string) => {
		setOptimisticDeletedThreadIds((current) => {
			if (!current.has(chatId)) {
				return current;
			}

			const next = new Set(current);
			next.delete(chatId);
			return next;
		});
	}, []);

	const deleteThread = async (chat: (typeof chats)[number]) => {
		const chatId = chat.id;
		markThreadDeleteOptimistic(chatId);

		try {
			await deleteChat(chatId);
			showThreadToast({
				message: `Thread "${chat.title}" deleted.`,
				type: "success",
			});
		} catch (error: unknown) {
			revertThreadDeletionOptimistic(chatId);
			showThreadToast({
				message: error instanceof Error ? error.message : "Failed to delete thread.",
				type: "error",
			});
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-threads"
		>
			<IosStackHeader
				left={<MaterialIcons color={palette.text} name="chevron-left" size={24} />}
				onBack={() => {
					goBackOr("/workspaces");
				}}
				subtitle={selectedProject?.name ?? "No workspace selected"}
				title="Threads"
			/>

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				keyboardShouldPersistTaps="handled"
				showsVerticalScrollIndicator={false}
			>
				<View style={styles.actionsRow}>
					<TextInput
						autoCapitalize="none"
						onChangeText={setSearchValue}
						placeholder="Search threads"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="threads-search-input"
						value={searchValue}
					/>
				</View>

				{shouldShowThreadsLoading ? (
					<View style={styles.loading}>
						<ActivityIndicator color={palette.accent} />
					</View>
				) : (
					<View style={styles.list}>
						{visibleThreads.length === 0 ? (
							<Text style={styles.supportText}>No thread found.</Text>
						) : (
							visibleThreads.map((chat, index) => (
								<SwipeableThreadItem
									isLoading={openingThreadId === chat.id}
									index={index}
									isWorking={activeThreadIds.has(chat.id)}
									isSelected={chat.id === selectedChatId}
									chat={chat}
									key={chat.id}
									onLongPress={() => {
										setThreadActionTarget(chat);
									}}
									rowTestID={`thread-item-${String(index)}`}
									onOpenChat={() => {
										openThread(chat);
									}}
								/>
							))
						)}
					</View>
				)}

				{effectiveErrorMessage.length > 0 ? (
					<View style={styles.errorBox}>
						<Text selectable style={styles.errorText}>
							{effectiveErrorMessage}
						</Text>
					</View>
				) : null}
			</ScrollView>
			<ActiveThreadsFooterCta
				count={selectedProjectActiveThreadsCount}
				isLoading={isActiveThreadsLoading}
				onPress={() => {
					push("/active-threads");
				}}
				testID="threads-active-threads-cta"
			/>
			<Pressable
				accessibilityLabel="threads-new-button"
				accessibilityRole="button"
				disabled={isCreating}
				onPress={() => {
					void createThread();
				}}
				style={({ pressed }) => [
					styles.fabButton,
					pressed ? styles.fabButtonPressed : null,
					isCreating ? styles.disabledButton : null,
				]}
				testID="threads-new-button"
			>
				{isCreating ? (
					<ActivityIndicator color={palette.background} size="small" />
				) : (
					<MaterialIcons color="#0A1D2B" name="add" size={30} />
				)}
			</Pressable>
			{toastMessage ? (
				<Animated.View style={[styles.toastContainer, { opacity: toastOpacity }]} pointerEvents="none">
					<View
						style={[
							styles.toast,
							toastMessage.type === "success" ? styles.toastSuccess : styles.toastError,
						]}
					>
						<Text style={styles.toastText}>{toastMessage.message}</Text>
					</View>
				</Animated.View>
			) : null}
			<IosActionSheet
				actions={[
					{
						icon: "delete-outline",
						key: "delete-thread",
						label: "Delete thread",
						onPress: () => {
							if (!threadActionTarget) {
								return;
							}
							void deleteThread(threadActionTarget);
						},
						testID: "thread-item-delete",
						tone: "destructive",
					},
				]}
				onClose={() => {
					setThreadActionTarget(null);
				}}
				testID="thread-action-sheet"
				title={threadActionTarget?.title ?? "Thread options"}
				isVisible={threadActionTarget !== null}
			/>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	actionsRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
	},
	content: {
		gap: 12,
		paddingBottom: 112,
		paddingHorizontal: 16,
		paddingTop: 14,
	},
	errorBox: {
		backgroundColor: "rgba(255,107,133,0.16)",
		borderColor: "rgba(255,107,133,0.38)",
		borderRadius: 12,
		borderWidth: 1,
		padding: 12,
	},
	errorText: {
		color: palette.text,
		fontSize: 13,
	},
	input: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		color: palette.text,
		flex: 1,
		fontSize: 15,
		minHeight: 42,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	list: {
		backgroundColor: "#12161E",
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		gap: 8,
		padding: 10,
	},
	loading: {
		alignItems: "center",
		paddingVertical: 20,
	},
	fabButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 29,
		bottom: 22,
		elevation: 9,
		height: 58,
		justifyContent: "center",
		position: "absolute",
		right: 18,
		width: 58,
		zIndex: 30,
		shadowColor: "#00111F",
		shadowOffset: {
			height: 4,
			width: 0,
		},
		shadowOpacity: 0.34,
		shadowRadius: 10,
	},
	fabButtonPressed: {
		backgroundColor: palette.accentPressed,
		opacity: 0.93,
	},
	disabledButton: {
		opacity: 0.45,
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	rowMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	rowTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "600",
	},
	supportText: {
		color: palette.muted,
		fontSize: 13,
		padding: 8,
	},
	toast: {
		alignItems: "center",
		borderRadius: 10,
		borderWidth: 1,
		paddingHorizontal: 14,
		paddingVertical: 10,
	},
	toastContainer: {
		left: 16,
		position: "absolute",
		right: 16,
		alignItems: "center",
		bottom: 28,
		display: "flex",
		zIndex: 50,
	},
	toastError: {
		backgroundColor: "rgba(255,93,95,0.22)",
		borderColor: "rgba(255,93,95,0.75)",
	},
	toastSuccess: {
		backgroundColor: "rgba(99,200,255,0.22)",
		borderColor: "rgba(99,200,255,0.75)",
	},
	toastText: {
		color: palette.text,
		fontSize: 12,
		fontWeight: "600",
		textAlign: "center",
	},
});
