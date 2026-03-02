import { useQuery } from "@tanstack/react-query";
import { useRouter } from "expo-router";
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
import { formatRelativeTime } from "../../../shared/lib/time";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
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

export const ThreadSelectionScreen = () => {
	const router = useRouter();
	const api = useRemoteCodeClient();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const {
		chats,
		createChat,
		isLoaded,
		selectChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
	} = useWorkspaceShell();
	const [searchValue, setSearchValue] = useState<string>("");
	const [isCreating, setIsCreating] = useState<boolean>(false);
	const [errorMessage, setErrorMessage] = useState<string>("");

	const serverHealthQuery = useQuery({
		enabled: isConfigLoaded,
		queryKey: ["mobile-server-health-threads", config.baseUrl, config.token],
		queryFn: async () => await api.verifyToken(config.token, config.baseUrl),
		retry: 1,
		staleTime: 30_000,
	});

	useEffect(() => {
		let timeoutId: ReturnType<typeof setTimeout> | null = null;

		if (isConfigLoaded && isLoaded && !serverHealthQuery.isPending) {
			if (serverHealthQuery.isError) {
				router.replace("/settings");
			} else {
				timeoutId = setTimeout(() => {
					if (!selectedProjectId) {
						router.replace("/workspaces");
					}
				}, 650);
			}
		}

		return () => {
			if (timeoutId !== null) {
				clearTimeout(timeoutId);
			}
		};
	}, [
		isConfigLoaded,
		isLoaded,
		router,
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
			return sorted;
		}

		return sorted.filter((chat) => chat.title.toLowerCase().includes(query));
	}, [chats, searchValue]);

	const openThread = (chat: (typeof chats)[number]) => {
		selectChat(chat);
		router.push("/chat");
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
				router.push("/chat");
			}
		} catch (error: unknown) {
			setErrorMessage(error instanceof Error ? error.message : "Failed to create thread.");
		} finally {
			setIsCreating(false);
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-threads"
		>
			<IosStackHeader subtitle={selectedProject?.name ?? "No workspace selected"} title="Threads" />

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
					<Pressable
						accessibilityLabel="threads-new-button"
						accessibilityRole="button"
						disabled={isCreating}
						onPress={() => {
							void createThread();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							isCreating ? styles.disabledButton : null,
						]}
						testID="threads-new-button"
					>
						<Text style={styles.primaryLabel}>{isCreating ? "..." : "New"}</Text>
					</Pressable>
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
								<Pressable
									accessibilityLabel={`thread-item-${String(index)}`}
									accessibilityRole="button"
									key={chat.id}
									onPress={() => {
										openThread(chat);
									}}
									style={({ pressed }) => [
										styles.listRow,
										chat.id === selectedChatId ? styles.listRowActive : null,
										pressed ? styles.listRowPressed : null,
									]}
									testID={`thread-item-${String(index)}`}
								>
									<Text numberOfLines={1} style={styles.rowTitle}>
										{chat.title}
									</Text>
									<Text style={styles.rowMeta}>Updated {formatRelativeTime(chat.updatedAt)}</Text>
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
	actionsRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
	},
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
	listRow: {
		borderColor: palette.border,
		borderRadius: 11,
		borderWidth: 1,
		gap: 4,
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
		height: 40,
		justifyContent: "center",
		minWidth: 58,
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
});
