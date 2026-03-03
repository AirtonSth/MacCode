import { useQuery } from "@tanstack/react-query";
import { MaterialIcons } from "@expo/vector-icons";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
	ActivityIndicator,
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";

import { useWorkspaceShell } from "../../chat/model/use-workspace-shell";
import { DesktopFilePickerModal } from "../../chat/ui/desktop-file-picker-modal";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { SwipeableWorkspaceItem } from "./swipeable-workspace-item";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

export const WorkspaceSelectionScreen = () => {
	const api = useRemoteCodeClient();
	const { push, replace } = useFlowNavigator();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const {
		createProject,
		deleteProject,
		isLoaded,
		isChatsLoading,
		projects,
		selectProject,
		selectedProjectId,
	} = useWorkspaceShell();
	const [searchValue, setSearchValue] = useState<string>("");
	const [isDesktopPickerVisible, setIsDesktopPickerVisible] = useState<boolean>(false);
	const [isCreatingFromFab, setIsCreatingFromFab] = useState<boolean>(false);
	const [openSwipeRowId, setOpenSwipeRowId] = useState<string | null>(null);
	const [openingWorkspaceId, setOpeningWorkspaceId] = useState<string | null>(null);
	const [optimisticDeletedWorkspaceIds, setOptimisticDeletedWorkspaceIds] = useState<Set<string>>(
		new Set(),
	);
	const [errorMessage, setErrorMessage] = useState<string>("");

	const serverHealthQuery = useQuery({
		enabled: isConfigLoaded,
		queryKey: ["mobile-server-health-workspaces", config.baseUrl, config.token],
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
		}
	}, [
		isConfigLoaded,
		isLoaded,
		replace,
		serverHealthQuery.isError,
		serverHealthQuery.isPending,
	]);

	const visibleProjects = useMemo(() => {
		const query = searchValue.trim().toLowerCase();
		const sorted = Array.from(projects).sort((left, right) => {
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
			(project) =>
				project.name.toLowerCase().includes(query) || project.path.toLowerCase().includes(query),
		);
	}, [optimisticDeletedWorkspaceIds, projects, searchValue]);

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

	const openWorkspace = (project: (typeof projects)[number]) => {
		setOpenSwipeRowId(null);
		setOpeningWorkspaceId(project.id);
		selectProject(project);
		push("/threads");
	};

	const createWorkspaceFromDesktopPaths = async (paths: string[]) => {
		const selectedPath = paths[0]?.trim();
		if (!selectedPath) {
			setErrorMessage("Select a folder to create a workspace.");
			return;
		}

		setIsDesktopPickerVisible(false);
		setIsCreatingFromFab(true);
		setErrorMessage("");
		try {
			await createProject({ path: selectedPath });
			push("/threads");
		} catch (error: unknown) {
			setErrorMessage(error instanceof Error ? error.message : "Failed to create workspace.");
		} finally {
			setIsCreatingFromFab(false);
		}
	};

	const deleteWorkspace = async (project: (typeof projects)[number]) => {
		setOpenSwipeRowId((current) => (current === project.id ? null : current));
		markWorkspaceDeleteOptimistic(project.id);

		try {
			await deleteProject(project.id);
		} catch (error: unknown) {
			revertWorkspaceDeletionOptimistic(project.id);
			setErrorMessage(error instanceof Error ? error.message : "Failed to delete workspace.");
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-workspaces"
		>
			<IosStackHeader subtitle="Select workspace" title="Workspaces" />

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
						placeholder="Search workspaces"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="workspaces-search-input"
						value={searchValue}
					/>
				</View>

				{!isLoaded ? (
					<View style={styles.loading}>
						<ActivityIndicator color={palette.accent} />
					</View>
				) : (
					<View style={styles.list}>
						{visibleProjects.length === 0 ? (
							<Text style={styles.supportText}>No workspace found.</Text>
						) : (
							visibleProjects.map((project, index) => (
								<SwipeableWorkspaceItem
									isLoading={openingWorkspaceId === project.id}
									deleteTestID={`workspace-item-delete-${String(index)}`}
									index={index}
									isActive={openSwipeRowId === project.id}
									isSelected={project.id === selectedProjectId}
									key={project.id}
									onClose={() => {
										setOpenSwipeRowId((current) => (current === project.id ? null : current));
									}}
									onDelete={() => {
										void deleteWorkspace(project);
									}}
									onOpen={() => {
										setOpenSwipeRowId(project.id);
									}}
									onOpenWorkspace={() => {
										openWorkspace(project);
									}}
									project={project}
									rowTestID={`workspace-item-${String(index)}`}
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
				accessibilityRole="button"
				disabled={isCreatingFromFab}
				onPress={() => {
					setErrorMessage("");
					setIsDesktopPickerVisible(true);
				}}
				style={({ pressed }) => [
					styles.fabButton,
					pressed ? styles.fabButtonPressed : null,
					isCreatingFromFab ? styles.disabledButton : null,
				]}
				testID="workspaces-create-fab"
			>
				{isCreatingFromFab ? (
					<ActivityIndicator color="#0A1D2B" size="small" />
				) : (
					<MaterialIcons color="#0A1D2B" name="add" size={30} />
				)}
			</Pressable>

			<DesktopFilePickerModal
				client={api}
				currentFolderAction="submit"
				entryScope="directories"
				isVisible={isDesktopPickerVisible}
				onAddPaths={(paths) => {
					void createWorkspaceFromDesktopPaths(paths);
				}}
				onClose={() => {
					if (isCreatingFromFab) {
						return;
					}

					setIsDesktopPickerVisible(false);
				}}
				selectionMode="single"
				isAddButtonVisible={false}
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
	disabledButton: {
		opacity: 0.45,
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
	loading: {
		alignItems: "center",
		justifyContent: "center",
		paddingVertical: 22,
	},
	list: {
		backgroundColor: "#12161E",
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		gap: 8,
		padding: 10,
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	supportText: {
		color: palette.muted,
		fontSize: 13,
		padding: 8,
	},
});
