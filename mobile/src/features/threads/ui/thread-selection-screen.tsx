import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useIsFocused } from "@react-navigation/native";
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
import { useServerHealthQuery } from "../../../shared/api/use-server-health-query";
import type { ProjectDTO } from "../../../shared/api/types";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { ActiveThreadsFooterCta } from "../../../shared/ui/active-threads-footer-cta";
import { IosActionSheet } from "../../../shared/ui/ios-action-sheet";
import { SwipeableThreadItem } from "./swipeable-thread-item";
import { SwipeableWorkspaceItem } from "../../workspaces/ui/swipeable-workspace-item";
import { WorkspaceRenameModal } from "../../workspaces/ui/workspace-rename-modal";
import { DesktopFilePickerModal } from "../../chat/ui/desktop-file-picker-modal";

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
	const { push, replace } = useFlowNavigator();
	const { isLoaded: isConfigLoaded } = useApiConfig();
	const isFocused = useIsFocused();
	const [isDrawerOpen, setIsDrawerOpen] = useState<boolean>(false);
	const {
		activeThreads,
		chats,
		chatsErrorMessage,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		isLoaded,
		isActiveThreadsLoading,
		isChatsLoading,
		isMessagesLoading,
		projects,
		renameProject,
		selectChat,
		selectProject,
		selectedChatId,
		selectedProject,
		selectedProjectId,
	} = useWorkspaceShell({
		isActive: isFocused,
		scope: "threads",
		shouldLoadDrawerWorkspaces: isDrawerOpen,
	});
	const [searchValue, setSearchValue] = useState<string>("");
	const [drawerSearchValue, setDrawerSearchValue] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [isWorkspacePickerOpen, setIsWorkspacePickerOpen] = useState<boolean>(false);
	const [isCreatingWorkspaceFromDrawer, setIsCreatingWorkspaceFromDrawer] = useState<boolean>(false);
	const [openingThreadId, setOpeningThreadId] = useState<string | null>(null);
	const [openingWorkspaceId, setOpeningWorkspaceId] = useState<string | null>(null);
	const [optimisticDeletedThreadIds, setOptimisticDeletedThreadIds] = useState<Set<string>>(new Set());
	const [optimisticDeletedWorkspaceIds, setOptimisticDeletedWorkspaceIds] = useState<Set<string>>(new Set());
	const [toastMessage, setToastMessage] = useState<ToastPayload | null>(null);
	const [threadActionTarget, setThreadActionTarget] = useState<(typeof chats)[number] | null>(null);
	const [drawerWorkspaceActionTarget, setDrawerWorkspaceActionTarget] = useState<ProjectDTO | null>(null);
	const [workspaceNameInput, setWorkspaceNameInput] = useState<string>("");
	const [workspaceToRename, setWorkspaceToRename] = useState<ProjectDTO | null>(null);
	const [isRenamingWorkspace, setIsRenamingWorkspace] = useState<boolean>(false);
	const [errorMessage, setErrorMessage] = useState<string>("");
	const [drawerWorkspaceError, setDrawerWorkspaceError] = useState<string>("");
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

	const visibleWorkspaces = useMemo(() => {
		const query = drawerSearchValue.trim().toLowerCase();
		const sorted = Array.from(projects);
		sorted.sort((left, right) => {
			if (left.isFavorite !== right.isFavorite) {
				return left.isFavorite ? -1 : 1;
			}
			return left.name.localeCompare(right.name);
		});
		const filtered = sorted.filter((project) => !optimisticDeletedWorkspaceIds.has(project.id));

		if (!query) {
			return filtered;
		}

		return filtered.filter(
			(project) => project.name.toLowerCase().includes(query) || project.path.toLowerCase().includes(query),
		);
	}, [drawerSearchValue, optimisticDeletedWorkspaceIds, projects]);
	const shouldShowThreadsLoading = !isLoaded || isChatsLoading;
	const effectiveErrorMessage = errorMessage.length > 0 ? errorMessage : (chatsErrorMessage ?? "");

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
			setDrawerWorkspaceActionTarget(null);
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
			setDrawerWorkspaceActionTarget(null);
			onClosed();
		});
	};

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

	useEffect(() => {
		if (!openingWorkspaceId) {
			return;
		}

		if (selectedProjectId !== openingWorkspaceId) {
			return;
		}

		if (isChatsLoading) {
			return;
		}

		setOpeningWorkspaceId(null);
	}, [isChatsLoading, openingWorkspaceId, selectedProjectId]);

	const openWorkspaceFromDrawer = (project: (typeof projects)[number]) => {
		setErrorMessage("");
		setDrawerWorkspaceActionTarget(null);
		setOpeningWorkspaceId(project.id);
		selectProject(project);
		closeDrawer();
		replace("/threads");
	};

	const openSettingsFromDrawer = () => {
		closeDrawerThen(() => {
			replace("/settings");
		});
	};

	const createWorkspaceFromDrawer = async (paths: string[]) => {
		const selectedPath = paths[0]?.trim();
		if (!selectedPath) {
			setDrawerWorkspaceError("Select a folder to create a workspace.");
			return;
		}

		setIsWorkspacePickerOpen(false);
		setIsCreatingWorkspaceFromDrawer(true);
		setDrawerWorkspaceError("");
		try {
			await createProject({ path: selectedPath });
			closeDrawer();
			replace("/threads");
		} catch (error: unknown) {
			setDrawerWorkspaceError(error instanceof Error ? error.message : "Failed to create workspace.");
		} finally {
			setIsCreatingWorkspaceFromDrawer(false);
		}
	};

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

	const markWorkspaceDeleteOptimistic = useCallback((projectId: string) => {
		setOptimisticDeletedWorkspaceIds((current) => {
			if (current.has(projectId)) {
				return current;
			}

			const next = new Set(current);
			next.add(projectId);
			return next;
		});
	}, []);

	const revertWorkspaceDeletionOptimistic = useCallback((projectId: string) => {
		setOptimisticDeletedWorkspaceIds((current) => {
			if (!current.has(projectId)) {
				return current;
			}

			const next = new Set(current);
			next.delete(projectId);
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

	const deleteWorkspace = async (project: (typeof projects)[number]) => {
		const projectId = project.id;
		markWorkspaceDeleteOptimistic(projectId);

		try {
			await deleteProject(projectId);
			showThreadToast({
				message: `Workspace "${project.name}" deleted.`,
				type: "success",
			});
		} catch (error: unknown) {
			revertWorkspaceDeletionOptimistic(projectId);
			showThreadToast({
				message: error instanceof Error ? error.message : "Failed to delete workspace.",
				type: "error",
			});
		}
	};

	const closeRenameWorkspaceModal = useCallback(() => {
		if (isRenamingWorkspace) {
			return;
		}

		setWorkspaceToRename(null);
		setWorkspaceNameInput("");
	}, [isRenamingWorkspace]);

	const confirmRenameWorkspace = useCallback(async () => {
		if (!workspaceToRename) {
			return;
		}

		const nextName = workspaceNameInput.trim();
		if (nextName.length === 0) {
			showThreadToast({
				message: "Workspace name cannot be empty.",
				type: "error",
			});
			return;
		}

		if (nextName === workspaceToRename.name) {
			setWorkspaceToRename(null);
			setWorkspaceNameInput("");
			return;
		}

		setIsRenamingWorkspace(true);
		setDrawerWorkspaceError("");
		try {
			await renameProject(workspaceToRename.id, nextName);
			setWorkspaceToRename(null);
			setWorkspaceNameInput("");
			showThreadToast({
				message: `Workspace "${nextName}" renamed.`,
				type: "success",
			});
		} catch (error: unknown) {
			showThreadToast({
				message: error instanceof Error ? error.message : "Failed to rename workspace.",
				type: "error",
			});
		} finally {
			setIsRenamingWorkspace(false);
		}
	}, [renameProject, showThreadToast, workspaceNameInput, workspaceToRename]);

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
							<View style={styles.drawerHeader}>
								<Text style={styles.drawerTitle}>Workspaces</Text>
								<Pressable
									accessibilityLabel="drawer-create-workspace-button"
									accessibilityRole="button"
									disabled={isCreatingWorkspaceFromDrawer}
									hitSlop={8}
									onPress={() => {
										setDrawerWorkspaceError("");
										setIsWorkspacePickerOpen(true);
									}}
									style={({ pressed }) => [
										styles.drawerCreateButton,
										pressed ? styles.drawerCreateButtonPressed : null,
										isCreatingWorkspaceFromDrawer ? styles.disabledButton : null,
									]}
									testID="drawer-create-workspace-button"
								>
									{isCreatingWorkspaceFromDrawer ? (
										<ActivityIndicator color={palette.text} size="small" />
									) : (
										<MaterialIcons color={palette.text} name="add" size={18} />
									)}
								</Pressable>
							</View>
							{drawerWorkspaceError.length > 0 ? (
								<Text style={styles.drawerErrorText}>{drawerWorkspaceError}</Text>
							) : null}
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
									<SwipeableWorkspaceItem
										isLoading={openingWorkspaceId === project.id}
										index={index}
										isSelected={project.id === selectedProjectId}
										key={project.id}
										onLongPress={() => {
											setDrawerWorkspaceError("");
											setDrawerWorkspaceActionTarget(project);
										}}
										onOpenWorkspace={() => {
											openWorkspaceFromDrawer(project);
										}}
										project={project}
										rowBackgroundColor="rgba(255,255,255,0.04)"
										rowBorderColor="rgba(255,255,255,0.2)"
										selectedRowBackgroundColor="rgba(99,200,255,0.16)"
										selectedRowBorderColor="rgba(99,200,255,0.75)"
										rowTestID={`drawer-workspace-item-${String(index)}`}
									/>
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
			<DesktopFilePickerModal
				client={api}
				currentFolderAction="submit"
				entryScope="directories"
				isVisible={isWorkspacePickerOpen}
				onAddPaths={(paths) => {
					void createWorkspaceFromDrawer(paths);
				}}
				onClose={() => {
					if (isCreatingWorkspaceFromDrawer) {
						return;
					}

					setIsWorkspacePickerOpen(false);
				}}
				selectionMode="single"
				isAddButtonVisible={false}
			/>
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
			<IosActionSheet
				actions={[
					{
						icon: "edit",
						key: "rename-drawer-workspace",
						label: "Rename",
						onPress: () => {
							if (!drawerWorkspaceActionTarget) {
								return;
							}
							setWorkspaceToRename(drawerWorkspaceActionTarget);
							setWorkspaceNameInput(drawerWorkspaceActionTarget.name);
						},
						testID: "drawer-workspace-rename",
					},
					{
						icon: "delete-outline",
						key: "delete-drawer-workspace",
						label: "Delete",
						onPress: () => {
							if (!drawerWorkspaceActionTarget) {
								return;
							}
							void deleteWorkspace(drawerWorkspaceActionTarget);
						},
						testID: "drawer-workspace-delete",
						tone: "destructive",
					},
				]}
				onClose={() => {
					setDrawerWorkspaceActionTarget(null);
				}}
				testID="drawer-workspace-action-sheet"
				title={drawerWorkspaceActionTarget?.name ?? "Workspace options"}
				isVisible={drawerWorkspaceActionTarget !== null}
			/>
			<WorkspaceRenameModal
				isSubmitting={isRenamingWorkspace}
				isVisible={workspaceToRename !== null}
				name={workspaceNameInput}
				onCancel={closeRenameWorkspaceModal}
				onChangeName={setWorkspaceNameInput}
				onSubmit={() => {
					void confirmRenameWorkspace();
				}}
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
	drawerBackdrop: {
		backgroundColor: "rgba(0,0,0,0.45)",
		flex: 1,
	},
	drawerEmpty: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 12,
	},
	drawerErrorText: {
		color: "#FF8CA2",
		fontSize: 12,
		marginBottom: 8,
	},
	drawerCreateButton: {
		alignItems: "center",
		borderRadius: 10,
		height: 30,
		justifyContent: "center",
		width: 30,
	},
	drawerCreateButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	drawerHeader: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
		marginBottom: 10,
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
		marginBottom: 0,
	},
});
