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
import { formatRelativeTime } from "../../../shared/lib/time";

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

export const ThreadSelectionScreen = () => {
	const router = useRouter();
	const {
		chats,
		createChat,
		isLoaded,
		selectChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
	} = useWorkspaceShell();
	const [newThreadTitle, setNewThreadTitle] = useState<string>("");
	const [searchValue, setSearchValue] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [errorMessage, setErrorMessage] = useState<string | null>(null);

	const filteredChats = useMemo(() => {
		const query = searchValue.trim().toLowerCase();
		const sortedChats = Array.from(chats).sort((left, right) =>
			new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime(),
		);

		if (!query) {
			return sortedChats;
		}

		return sortedChats.filter((chat) => chat.title.toLowerCase().includes(query));
	}, [chats, searchValue]);

	const createThread = async () => {
		if (!selectedProjectId) {
			setErrorMessage("Select a workspace first.");
			return;
		}

		setIsCreating(true);
		setErrorMessage(null);

		try {
			const newChat = await createChat(newThreadTitle.trim() || "New thread");
			if (newChat) {
				setNewThreadTitle("");
				router.push("/chat");
			}
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to create thread.");
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
				<Text style={styles.stepLabel}>STEP 3 OF 4</Text>
				<View style={styles.progressRow}>
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={styles.progressDot} />
				</View>

				<View style={styles.headerRow}>
					<View style={styles.headerTextContainer}>
						<Text style={styles.title}>Choose a thread</Text>
						<Text numberOfLines={1} style={styles.subtitle}>
							{selectedProject ? selectedProject.name : "No workspace selected"}
						</Text>
					</View>
					<Pressable
						onPress={() => {
							router.push("/workspaces");
						}}
						style={({ pressed }) => [
							styles.secondaryButton,
							pressed ? styles.secondaryButtonPressed : null,
						]}
					>
						<Text style={styles.secondaryButtonLabel}>Workspaces</Text>
					</Pressable>
				</View>

				{!selectedProjectId ? (
					<View style={styles.card}>
						<Text style={styles.cardTitle}>Workspace required</Text>
						<Text style={styles.cardDescription}>
							Select a workspace before choosing a thread.
						</Text>
						<Pressable
							onPress={() => {
								router.push("/workspaces");
							}}
							style={({ pressed }) => [
								styles.primaryButton,
								pressed ? styles.primaryButtonPressed : null,
							]}
						>
							<Text style={styles.primaryButtonLabel}>Go to workspaces</Text>
						</Pressable>
					</View>
				) : (
					<>
						<View style={styles.card}>
							<Text style={styles.cardTitle}>Create a new thread</Text>
							<TextInput
								onChangeText={setNewThreadTitle}
								placeholder="Thread title (optional)"
								placeholderTextColor={palette.muted}
								style={styles.input}
								value={newThreadTitle}
							/>
							<Pressable
								disabled={isCreating}
								onPress={() => {
									void createThread();
								}}
								style={({ pressed }) => [
									styles.primaryButton,
									pressed ? styles.primaryButtonPressed : null,
									isCreating ? styles.disabledButton : null,
								]}
							>
								<Text style={styles.primaryButtonLabel}>{isCreating ? "Creating..." : "Create and open chat"}</Text>
							</Pressable>
						</View>

						<View style={styles.card}>
							<Text style={styles.cardTitle}>Recent threads</Text>
							<TextInput
								autoCapitalize="none"
								onChangeText={setSearchValue}
								placeholder="Search threads"
								placeholderTextColor={palette.muted}
								style={styles.input}
								value={searchValue}
							/>

							{!isLoaded ? <ActivityIndicator color={palette.accent} style={styles.loader} /> : null}

							{isLoaded && filteredChats.length === 0 ? (
								<Text style={styles.emptyText}>No threads yet. Create one above.</Text>
							) : null}

							{filteredChats.map((chat) => (
								<Pressable
									key={chat.id}
									onPress={() => {
										selectChat(chat);
										router.push("/chat");
									}}
									style={({ pressed }) => [
										styles.threadItem,
										chat.id === selectedChatId ? styles.threadItemActive : null,
										pressed ? styles.threadItemPressed : null,
									]}
								>
									<Text numberOfLines={1} style={styles.threadTitle}>
										{chat.title}
									</Text>
									<Text style={styles.threadMeta}>
										Updated {formatRelativeTime(chat.updatedAt)}
									</Text>
								</Pressable>
							))}
						</View>
					</>
				)}

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
	cardDescription: {
		color: palette.muted,
		fontSize: 14,
		lineHeight: 20,
		marginTop: 4,
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
	threadItem: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		gap: 6,
		marginTop: 10,
		minHeight: 62,
		padding: 12,
	},
	threadItemActive: {
		borderColor: "rgba(109, 227, 194, 0.42)",
	},
	threadItemPressed: {
		backgroundColor: "rgba(255,255,255,0.12)",
	},
	threadMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	threadTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "700",
	},
	title: {
		color: palette.text,
		fontSize: 28,
		fontWeight: "800",
	},
});
