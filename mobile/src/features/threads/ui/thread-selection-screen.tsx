import { useQuery } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
	ActivityIndicator,
	Animated,
	KeyboardAvoidingView,
	Platform,
	Modal,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";
import { MaterialIcons } from "@expo/vector-icons";
import { LinearGradient } from "expo-linear-gradient";

import { useWorkspaceShell } from "../../chat/model/use-workspace-shell";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
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

const drawerWidth = 308;
interface ToastPayload {
	message: string;
	type: "error" | "success";
}

export const ThreadSelectionScreen = () => {
	const api = useRemoteCodeClient();
	const { replace } = useFlowNavigator();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const {
		chats,
		createChat,
		deleteChat,
		isLoaded,
		projects,
		selectChat,
		selectProject,
		selectedChatId,
		selectedProject,
		selectedProjectId,
	} = useWorkspaceShell();
	const [searchValue, setSearchValue] = useState<string>("");
	const [drawerSearchValue, setDrawerSearchValue] = useState<string>("");
	const [isDrawerOpen, setIsDrawerOpen] = useState<boolean>(false);
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [optimisticDeletedThreadIds, setOptimisticDeletedThreadIds] = useState<Set<string>>(new Set());
	const [toastMessage, setToastMessage] = useState<ToastPayload | null>(null);
	const [openSwipeRowId, setOpenSwipeRowId] = useState<string | null>(null);
	const [errorMessage, setErrorMessage] = useState<string>("");
	const drawerTranslate = useMemo(() => new Animated.Value(-drawerWidth), []);
	const drawerOpacity = useMemo(() => new Animated.Value(0), []);
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

	const serverHealthQuery = useQuery({
		enabled: isConfigLoaded,
		queryKey: ["mobile-server-health-threads", config.baseUrl, config.token],
		queryFn: async () => await api.verifyToken(config.token, config.baseUrl),
		retry: 1,
		staleTime: 30_000,
	});

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

	const visibleWorkspaces = useMemo(() => {
		const query = drawerSearchValue.trim().toLowerCase();
		const sorted = Array.from(projects);
		sorted.sort((left, right) => {
			if (left.isFavorite !== right.isFavorite) {
				return left.isFavorite ? -1 : 1;
			}
			return left.name.localeCompare(right.name);
		});

		if (!query) {
			return sorted;
		}

		return sorted.filter(
			(project) => project.name.toLowerCase().includes(query) || project.path.toLowerCase().includes(query),
		);
	}, [drawerSearchValue, projects]);

	const openDrawer = () => {
		setIsDrawerOpen(true);
		Animated.parallel([
			Animated.timing(drawerOpacity, {
				duration: 150,
				toValue: 1,
				useNativeDriver: true,
			}),
			Animated.timing(drawerTranslate, {
				duration: 190,
				toValue: 0,
				useNativeDriver: true,
			}),
		]).start();
	};

	const closeDrawer = () => {
		Animated.parallel([
			Animated.timing(drawerOpacity, {
				duration: 140,
				toValue: 0,
				useNativeDriver: true,
			}),
			Animated.timing(drawerTranslate, {
				duration: 170,
				toValue: -drawerWidth,
				useNativeDriver: true,
			}),
		]).start(() => {
			setIsDrawerOpen(false);
		});
	};

	const closeDrawerThen = (onClosed: () => void) => {
		Animated.parallel([
			Animated.timing(drawerOpacity, {
				duration: 140,
				toValue: 0,
				useNativeDriver: true,
			}),
			Animated.timing(drawerTranslate, {
				duration: 170,
				toValue: -drawerWidth,
				useNativeDriver: true,
			}),
		]).start(() => {
			setIsDrawerOpen(false);
			onClosed();
		});
	};

	const openWorkspaceFromDrawer = (project: (typeof projects)[number]) => {
		selectProject(project);
		closeDrawer();
		replace("/threads");
	};

	const openSettingsFromDrawer = () => {
		closeDrawerThen(() => {
			replace("/settings");
		});
	};

	const openThread = (chat: (typeof chats)[number]) => {
		selectChat(chat);
		replace({
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
				replace({
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
		setOpenSwipeRowId((current) => (current === chatId ? null : current));
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
				left={<MaterialIcons color={palette.text} name="menu" size={20} />}
				onBack={openDrawer}
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

				{!isLoaded ? (
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
									index={index}
									isActive={openSwipeRowId === chat.id}
									isSelected={chat.id === selectedChatId}
									chat={chat}
									key={chat.id}
									onClose={() => {
										setOpenSwipeRowId((current) => (current === chat.id ? null : current));
									}}
									onDelete={() => {
										void deleteThread(chat);
									}}
									deleteTestID={`thread-item-delete-${String(index)}`}
									rowTestID={`thread-item-${String(index)}`}
									onOpen={() => {
										setOpenSwipeRowId(chat.id);
									}}
									onOpenChat={() => {
										openThread(chat);
									}}
								/>
							))
						)}
					</View>
				)}

				{errorMessage.length > 0 ? (
					<View style={styles.errorBox}>
						<Text selectable style={styles.errorText}>
							{errorMessage}
						</Text>
					</View>
				) : null}
			</ScrollView>
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
			<Modal animationType="none" onRequestClose={closeDrawer} transparent visible={isDrawerOpen}>
				<View style={styles.drawerRoot}>
					<Pressable onPress={closeDrawer} style={StyleSheet.absoluteFill}>
						<Animated.View style={[styles.drawerBackdrop, { opacity: drawerOpacity }]} />
					</Pressable>
					<Animated.View style={[styles.drawerPanel, { transform: [{ translateX: drawerTranslate }] }]}>
						<LinearGradient
							colors={["#1b2a40", "#29405d", "#3f4372", "#5b3b66"]}
							end={{
								x: 0,
								y: 1,
							}}
							style={styles.drawerPanelGradient}
							start={{
								x: 0,
								y: 0,
							}}
						>
							<Text style={styles.drawerTitle}>Workspaces</Text>
							<TextInput
								autoCapitalize="none"
								onChangeText={setDrawerSearchValue}
								placeholder="Search"
								placeholderTextColor={palette.muted}
								style={styles.drawerSearch}
								testID="drawer-workspaces-search-input"
								value={drawerSearchValue}
							/>

							<ScrollView
								style={styles.drawerListScroll}
								contentContainerStyle={styles.drawerList}
								contentInsetAdjustmentBehavior="automatic"
								showsVerticalScrollIndicator={false}
							>
								{visibleWorkspaces.length === 0 ? (
									<Text style={styles.drawerEmpty}>No workspace found.</Text>
								) : null}

							{visibleWorkspaces.map((project, index) => (
									<Pressable
										accessibilityLabel={`drawer-workspace-item-${String(index)}`}
										accessibilityRole="button"
										key={project.id}
										onPress={() => {
											openWorkspaceFromDrawer(project);
										}}
										style={({ pressed }) => [
											styles.drawerItem,
											project.id === selectedProjectId ? styles.drawerItemActive : null,
											pressed ? styles.drawerItemPressed : null,
										]}
										testID={`drawer-workspace-item-${String(index)}`}
									>
										<Text numberOfLines={1} style={styles.drawerItemTitle}>
											{project.name}
										</Text>
										<Text numberOfLines={1} style={styles.drawerItemMeta}>
											{project.path}
										</Text>
									</Pressable>
								))}
							</ScrollView>
								<View style={styles.drawerFooter}>
									<Pressable
										onPress={() => {
											openSettingsFromDrawer();
										}}
										style={({ pressed }) => [
											styles.drawerFooterButton,
											pressed ? styles.drawerFooterButtonPressed : null,
										]}
										testID="drawer-settings-button"
									>
										<MaterialIcons
											color={palette.text}
											name="settings"
											size={17}
										/>
										<Text numberOfLines={1} style={styles.drawerItemTitle}>
											Settings
										</Text>
									</Pressable>
								</View>
						</LinearGradient>
					</Animated.View>
				</View>
			</Modal>
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
	drawerBackdrop: {
		backgroundColor: "rgba(0,0,0,0.45)",
		flex: 1,
	},
	drawerEmpty: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 12,
	},
	drawerItem: {
		backgroundColor: "rgba(255,255,255,0.04)",
		borderColor: "rgba(255,255,255,0.2)",
		borderRadius: 11,
		borderWidth: 1,
		gap: 4,
		padding: 12,
	},
	drawerItemActive: {
		backgroundColor: "rgba(99,200,255,0.16)",
		borderColor: "rgba(99,200,255,0.75)",
	},
	drawerItemMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	drawerFooter: {
		borderTopColor: "rgba(255,255,255,0.2)",
		borderTopWidth: 1,
		marginTop: 10,
		paddingTop: 10,
		paddingHorizontal: 2,
		paddingBottom: Platform.OS === "ios" ? 34 : 16,
	},
	drawerFooterButton: {
		alignItems: "center",
		flexDirection: "row",
		gap: 10,
		padding: 12,
	},
	drawerFooterButtonPressed: {
		opacity: 0.75,
	},
	drawerItemPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	drawerItemTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "600",
	},
	drawerList: {
		gap: 8,
		paddingBottom: 20,
		paddingTop: 8,
	},
	drawerListScroll: {
		flex: 1,
	},
	drawerPanel: {
		elevation: 34,
		shadowColor: "#000",
		shadowOffset: {
			height: 14,
			width: 0,
		},
		shadowOpacity: 0.45,
		shadowRadius: 36,
		borderRightColor: palette.border,
		borderRightWidth: 1.2,
		bottom: 0,
		left: 0,
		position: "absolute",
		top: 0,
		width: drawerWidth,
	},
	drawerPanelGradient: {
		borderTopColor: "rgba(255,255,255,0.06)",
		borderTopWidth: StyleSheet.hairlineWidth,
		flex: 1,
		paddingHorizontal: 12,
		paddingTop: 58,
	},
	drawerRoot: {
		flex: 1,
	},
	drawerSearch: {
		backgroundColor: "rgba(255,255,255,0.10)",
		borderColor: "rgba(255,255,255,0.2)",
		borderRadius: 11,
		borderWidth: 1,
		color: "#F9FCFF",
		fontSize: 14,
		minHeight: 40,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	drawerTitle: {
		color: palette.text,
		fontSize: 18,
		fontWeight: "700",
		marginBottom: 10,
	},
});
