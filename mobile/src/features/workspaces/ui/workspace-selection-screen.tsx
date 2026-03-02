import { LinearGradient } from "expo-linear-gradient";
import { useRouter } from "expo-router";
import { useMemo, useState } from "react";
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

const palette = {
	accent: "#6DE3C2",
	accentPressed: "#53C9AB",
	background: "#050A15",
	card: "rgba(11, 24, 45, 0.86)",
	cardSoft: "rgba(10, 18, 34, 0.7)",
	line: "rgba(255, 255, 255, 0.12)",
	muted: "#93A6C7",
	text: "#F3F7FF",
};

export const WorkspaceSelectionScreen = () => {
	const router = useRouter();
	const { config } = useApiConfig();
	const {
		createProject,
		isLoaded,
		projects,
		selectProject,
		selectedProjectId,
	} = useWorkspaceShell();
	const [newWorkspacePath, setNewWorkspacePath] = useState<string>("");
	const [newWorkspaceName, setNewWorkspaceName] = useState<string>("");
	const [searchValue, setSearchValue] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [errorMessage, setErrorMessage] = useState<string | null>(null);

	const filteredProjects = useMemo(() => {
		const query = searchValue.trim().toLowerCase();
		const sortedProjects = Array.from(projects).sort((left, right) => {
			if (left.isFavorite !== right.isFavorite) {
				return left.isFavorite ? -1 : 1;
			}
			return left.name.localeCompare(right.name);
		});

		if (!query) {
			return sortedProjects;
		}

		return sortedProjects.filter((project) =>
			project.name.toLowerCase().includes(query) ||
			project.path.toLowerCase().includes(query),
		);
	}, [projects, searchValue]);

	const createWorkspace = async () => {
		const path = newWorkspacePath.trim();
		if (!path) {
			setErrorMessage("Workspace path is required.");
			return;
		}

		setIsCreating(true);
		setErrorMessage(null);

		try {
			await createProject({
				name: newWorkspaceName.trim() || undefined,
				path,
			});
			setNewWorkspaceName("");
			setNewWorkspacePath("");
			router.push("/threads");
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to create workspace.");
		} finally {
			setIsCreating(false);
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
		>
			<LinearGradient
				colors={["#1A2B50", "#0E1A35", palette.background]}
				end={{ x: 0.9, y: 1 }}
				start={{ x: 0.1, y: 0 }}
				style={StyleSheet.absoluteFill}
			/>

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				showsVerticalScrollIndicator={false}
			>
				<Text style={styles.stepLabel}>STEP 2 OF 4</Text>
				<View style={styles.progressRow}>
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={styles.progressDot} />
					<View style={styles.progressDot} />
				</View>

				<View style={styles.headerRow}>
					<View style={styles.headerTextContainer}>
						<Text style={styles.title}>Choose a workspace</Text>
						<Text numberOfLines={1} style={styles.subtitle}>
							Connected to {config.baseUrl}
						</Text>
					</View>
					<Pressable
						onPress={() => {
							router.replace("/");
						}}
						style={({ pressed }) => [
							styles.secondaryButton,
							pressed ? styles.secondaryButtonPressed : null,
						]}
					>
						<Text style={styles.secondaryButtonLabel}>Server</Text>
					</Pressable>
				</View>

				<View style={styles.card}>
					<Text style={styles.cardTitle}>Create workspace</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setNewWorkspacePath}
						placeholder="Absolute path (required)"
						placeholderTextColor={palette.muted}
						style={styles.input}
						value={newWorkspacePath}
					/>
					<TextInput
						autoCapitalize="none"
						onChangeText={setNewWorkspaceName}
						placeholder="Display name (optional)"
						placeholderTextColor={palette.muted}
						style={styles.input}
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
					>
						<Text style={styles.primaryButtonLabel}>{isCreating ? "Creating..." : "Create and continue"}</Text>
					</Pressable>
				</View>

				<View style={styles.card}>
					<Text style={styles.cardTitle}>Your workspaces</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setSearchValue}
						placeholder="Search by name or path"
						placeholderTextColor={palette.muted}
						style={styles.input}
						value={searchValue}
					/>

					{!isLoaded ? <ActivityIndicator color={palette.accent} style={styles.loader} /> : null}

					{isLoaded && filteredProjects.length === 0 ? (
						<Text style={styles.emptyText}>No workspace found. Create one above.</Text>
					) : null}

					{filteredProjects.map((project) => (
						<Pressable
							key={project.id}
							onPress={() => {
								selectProject(project);
								router.push("/threads");
							}}
							style={({ pressed }) => [
								styles.workspaceItem,
								project.id === selectedProjectId ? styles.workspaceItemActive : null,
								pressed ? styles.workspaceItemPressed : null,
							]}
						>
							<View style={styles.workspaceHeader}>
								<Text numberOfLines={1} style={styles.workspaceName}>
									{project.name}
								</Text>
								{project.isFavorite ? <Text style={styles.favoriteIcon}>★</Text> : null}
							</View>
							<Text numberOfLines={1} style={styles.workspacePath}>
								{project.path}
							</Text>
						</Pressable>
					))}
				</View>

				{errorMessage ? (
					<View style={styles.errorContainer}>
						<Text style={styles.errorText}>{errorMessage}</Text>
					</View>
				) : null}
			</ScrollView>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	card: {
		backgroundColor: palette.card,
		borderColor: palette.line,
		borderRadius: 20,
		borderWidth: 1,
		padding: 16,
	},
	cardTitle: {
		color: palette.text,
		fontSize: 17,
		fontWeight: "700",
		marginBottom: 10,
	},
	content: {
		gap: 16,
		paddingBottom: 36,
		paddingHorizontal: 18,
		paddingTop: 20,
	},
	disabledButton: {
		opacity: 0.45,
	},
	emptyText: {
		color: palette.muted,
		fontSize: 14,
		marginTop: 12,
	},
	errorContainer: {
		backgroundColor: "rgba(255, 118, 133, 0.12)",
		borderColor: "rgba(255, 118, 133, 0.35)",
		borderRadius: 14,
		borderWidth: 1,
		padding: 12,
	},
	errorText: {
		color: palette.text,
		fontSize: 13,
	},
	favoriteIcon: {
		color: palette.accent,
		fontSize: 14,
	},
	headerRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 12,
		justifyContent: "space-between",
	},
	headerTextContainer: {
		flex: 1,
		gap: 4,
	},
	input: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		color: palette.text,
		fontSize: 16,
		minHeight: 46,
		paddingHorizontal: 14,
		paddingVertical: 10,
	},
	loader: {
		marginTop: 14,
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 14,
		justifyContent: "center",
		marginTop: 12,
		minHeight: 46,
		paddingHorizontal: 14,
	},
	primaryButtonLabel: {
		color: "#062016",
		fontSize: 15,
		fontWeight: "800",
	},
	primaryButtonPressed: {
		backgroundColor: palette.accentPressed,
	},
	progressDot: {
		backgroundColor: "rgba(255,255,255,0.18)",
		borderRadius: 999,
		flex: 1,
		height: 6,
	},
	progressDotActive: {
		backgroundColor: palette.accent,
	},
	progressRow: {
		flexDirection: "row",
		gap: 6,
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	secondaryButton: {
		alignItems: "center",
		borderColor: palette.line,
		borderRadius: 12,
		borderWidth: 1,
		justifyContent: "center",
		minHeight: 40,
		paddingHorizontal: 14,
	},
	secondaryButtonLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	secondaryButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	stepLabel: {
		color: palette.muted,
		fontSize: 11,
		fontWeight: "700",
		letterSpacing: 1.2,
	},
	subtitle: {
		color: palette.muted,
		fontSize: 13,
	},
	title: {
		color: palette.text,
		fontSize: 28,
		fontWeight: "800",
	},
	workspaceHeader: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
	},
	workspaceItem: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		gap: 6,
		marginTop: 10,
		minHeight: 62,
		padding: 12,
	},
	workspaceItemActive: {
		borderColor: "rgba(109, 227, 194, 0.42)",
	},
	workspaceItemPressed: {
		backgroundColor: "rgba(255,255,255,0.12)",
	},
	workspaceName: {
		color: palette.text,
		flex: 1,
		fontSize: 15,
		fontWeight: "700",
		paddingRight: 8,
	},
	workspacePath: {
		color: palette.muted,
		fontSize: 12,
	},
});
