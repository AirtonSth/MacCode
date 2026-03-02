import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
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
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";

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
	const { replace } = useFlowNavigator();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const { createProject, isLoaded, projects, selectProject, selectedProjectId } = useWorkspaceShell();
	const [searchValue, setSearchValue] = useState<string>("");
	const [newWorkspaceName, setNewWorkspaceName] = useState<string>("");
	const [newWorkspacePath, setNewWorkspacePath] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
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

		if (!query) {
			return sorted;
		}

		return sorted.filter((item) =>
			item.name.toLowerCase().includes(query) || item.path.toLowerCase().includes(query),
		);
	}, [projects, searchValue]);

	const openWorkspace = (project: (typeof projects)[number]) => {
		selectProject(project);
		replace("/threads");
	};

	const createWorkspace = async () => {
		const path = newWorkspacePath.trim();
		if (!path) {
			setErrorMessage("Workspace path is required.");
			return;
		}

		setIsCreating(true);
		setErrorMessage("");
		try {
			await createProject({
				name: newWorkspaceName.trim() || undefined,
				path,
			});
			setNewWorkspaceName("");
			setNewWorkspacePath("");
			replace("/threads");
		} catch (error: unknown) {
			setErrorMessage(error instanceof Error ? error.message : "Failed to create workspace.");
		} finally {
			setIsCreating(false);
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
				<TextInput
					autoCapitalize="none"
					onChangeText={setSearchValue}
					placeholder="Search workspaces"
					placeholderTextColor={palette.muted}
					style={styles.input}
					testID="workspaces-search-input"
					value={searchValue}
				/>

				<View style={styles.section}>
					<Text style={styles.sectionTitle}>Create Workspace</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setNewWorkspacePath}
						placeholder="Path (required)"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="workspaces-create-path-input"
						value={newWorkspacePath}
					/>
					<TextInput
						autoCapitalize="none"
						onChangeText={setNewWorkspaceName}
						placeholder="Name (optional)"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="workspaces-create-name-input"
						value={newWorkspaceName}
					/>
					<Pressable
						disabled={isCreating}
						onPress={() => {
							void createWorkspace();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							isCreating ? styles.disabledButton : null,
						]}
						testID="workspaces-create-button"
					>
						<Text style={styles.primaryLabel}>{isCreating ? "Creating..." : "Create"}</Text>
					</Pressable>
				</View>

				{!isLoaded ? (
					<View style={styles.loading}>
						<ActivityIndicator color={palette.accent} />
					</View>
				) : (
					<View style={styles.section}>
						<Text style={styles.sectionTitle}>Your Workspaces</Text>
						{visibleProjects.length === 0 ? (
							<Text style={styles.supportText}>No workspace available.</Text>
						) : (
							visibleProjects.map((project, index) => (
								<Pressable
									accessibilityLabel={`workspace-item-${String(index)}`}
									accessibilityRole="button"
									key={project.id}
									onPress={() => {
										openWorkspace(project);
									}}
									style={({ pressed }) => [
										styles.listRow,
										project.id === selectedProjectId ? styles.listRowActive : null,
										pressed ? styles.listRowPressed : null,
									]}
									testID={`workspace-item-${String(index)}`}
								>
									<View style={styles.rowHeader}>
										<Text numberOfLines={1} style={styles.rowTitle}>
											{project.name}
										</Text>
										{project.isFavorite ? <Text style={styles.favoriteMark}>Favorite</Text> : null}
									</View>
									<Text numberOfLines={1} style={styles.rowMeta}>
										{project.path}
									</Text>
								</Pressable>
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
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	content: {
		gap: 12,
		paddingBottom: 36,
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
	favoriteMark: {
		color: palette.accent,
		fontSize: 11,
		fontWeight: "600",
	},
	input: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		color: palette.text,
		fontSize: 15,
		minHeight: 42,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	listRow: {
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		gap: 6,
		padding: 12,
	},
	listRowActive: {
		borderColor: "rgba(99,200,255,0.45)",
	},
	listRowPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	loading: {
		alignItems: "center",
		paddingVertical: 20,
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 11,
		height: 38,
		justifyContent: "center",
		paddingHorizontal: 12,
	},
	primaryButtonPressed: {
		backgroundColor: palette.accentPressed,
	},
	primaryLabel: {
		color: "#0A1D2B",
		fontSize: 13,
		fontWeight: "700",
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	rowHeader: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
	},
	rowMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	rowTitle: {
		color: palette.text,
		flex: 1,
		fontSize: 15,
		fontWeight: "600",
	},
	section: {
		backgroundColor: "#12161E",
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		gap: 10,
		padding: 12,
	},
	sectionTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "700",
	},
	supportText: {
		color: palette.muted,
		fontSize: 13,
	},
});
