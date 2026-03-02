import { useQuery } from "@tanstack/react-query";
import { MaterialIcons } from "@expo/vector-icons";
import { LinearGradient } from "expo-linear-gradient";
import { useRouter } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import {
	Animated,
	KeyboardAvoidingView,
	Modal,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";

import { useWorkspaceShell } from "../model/use-workspace-shell";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import type { TerminalCommandDTO, TerminalEntryDTO } from "../../../shared/api/types";
import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { MessageMarkdown } from "../../../shared/ui/markdown-message";

const drawerWidth = 308;

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
	userBubble: "rgba(99,200,255,0.19)",
};

const toTerminalTranscript = (
	commands: TerminalCommandDTO[],
	entries: TerminalEntryDTO[],
): string => {
	const byCommandId = new Map<string, TerminalEntryDTO[]>();
	for (const entry of entries) {
		const list = byCommandId.get(entry.commandId) ?? [];
		list.push(entry);
		byCommandId.set(entry.commandId, list);
	}

	const sortedCommands = Array.from(commands);
	sortedCommands.sort(
		(left, right) => new Date(left.startedAt).getTime() - new Date(right.startedAt).getTime(),
	);

	const chunks: string[] = [];
	for (const command of sortedCommands) {
		const commandEntries = Array.from(byCommandId.get(command.id) ?? []);
		commandEntries.sort((left, right) => left.id - right.id);
		const output = commandEntries.map((item) => item.data).join("").trimEnd();
		const header = `$ ${command.command}`;
		chunks.push(output.length > 0 ? `${header}\n${output}` : header);
	}

	if (chunks.length === 0) {
		return "No terminal output yet.";
	}

	return chunks.join("\n\n");
};

export const ChatScreen = () => {
	const router = useRouter();
	const api = useRemoteCodeClient();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const {
		createChat,
		isLoaded,
		isSending,
		lastError,
		messages,
		projects,
		selectProject,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage,
		streamingText,
	} = useWorkspaceShell();
	const [input, setInput] = useState<string>("");
	const [drawerSearchValue, setDrawerSearchValue] = useState<string>("");
	const [isDrawerOpen, setIsDrawerOpen] = useState<boolean>(false);
	const [isTerminalOpen, setIsTerminalOpen] = useState<boolean>(false);
	const [terminalInput, setTerminalInput] = useState<string>("");
	const [terminalOutput, setTerminalOutput] = useState<string>("");
	const [terminalError, setTerminalError] = useState<string>("");
	const [isTerminalLoading, setIsTerminalLoading] = useState<boolean>(false);
	const [isTerminalRunning, setIsTerminalRunning] = useState<boolean>(false);
	const messageScrollRef = useRef<ScrollView | null>(null);
	const terminalScrollRef = useRef<ScrollView | null>(null);
	const drawerTranslate = useRef<Animated.Value>(new Animated.Value(-drawerWidth)).current;
	const drawerOpacity = useRef<Animated.Value>(new Animated.Value(0)).current;

	const serverHealthQuery = useQuery({
		enabled: isConfigLoaded,
		queryKey: ["mobile-server-health-chat", config.baseUrl, config.token],
		queryFn: async () => await api.verifyToken(config.token, config.baseUrl),
		retry: 1,
		staleTime: 30_000,
	});

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

		return sorted.filter((project) =>
			project.name.toLowerCase().includes(query) || project.path.toLowerCase().includes(query),
		);
	}, [projects, drawerSearchValue]);

	useEffect(() => {
		messageScrollRef.current?.scrollToEnd({ animated: true });
	}, [messages.length, streamingText]);

	useEffect(() => {
		let timeoutId: ReturnType<typeof setTimeout> | null = null;

		if (isConfigLoaded && isLoaded && !serverHealthQuery.isPending) {
			if (serverHealthQuery.isError) {
				router.replace("/settings");
			} else {
				timeoutId = setTimeout(() => {
					if (!selectedProjectId) {
						router.replace("/workspaces");
						return;
					}

					if (!selectedChatId) {
						router.replace("/threads");
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
		selectedChatId,
		selectedProjectId,
		serverHealthQuery.isError,
		serverHealthQuery.isPending,
	]);

	useEffect(() => {
		let active = true;
		const loadHistory = async () => {
			if (!isTerminalOpen || !selectedChatId) {
				return;
			}

			setIsTerminalLoading(true);
			setTerminalError("");
			try {
				const history = await api.getTerminalHistory(selectedChatId, { limit: 200 });
				if (!active) {
					return;
				}
				setTerminalOutput(toTerminalTranscript(history.commands, history.entries));
				setTimeout(() => {
					terminalScrollRef.current?.scrollToEnd({ animated: false });
				}, 0);
			} catch (error: unknown) {
				if (!active) {
					return;
				}
				setTerminalError(error instanceof Error ? error.message : "Unable to load terminal history.");
			} finally {
				if (active) {
					setIsTerminalLoading(false);
				}
			}
		};

		void loadHistory();

		return () => {
			active = false;
		};
	}, [api, isTerminalOpen, selectedChatId]);

	const submit = async () => {
		const text = input.trim();
		if (!text) {
			return;
		}

		const sent = await sendMessage(text);
		if (sent) {
			setInput("");
		}
	};

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

	const openWorkspaceFromDrawer = (project: (typeof projects)[number]) => {
		selectProject(project);
		closeDrawer();
		router.push("/threads");
	};

	const createQuickChat = async () => {
		const chat = await createChat("New chat");
		if (chat) {
			router.push("/chat");
		}
	};

	const runTerminalCommand = async () => {
		const command = terminalInput.trim();
		if (!selectedChatId || command.length === 0) {
			return;
		}

		setIsTerminalRunning(true);
		setTerminalError("");
		try {
			const result = await api.execTerminalCommand(selectedChatId, { command });
			const output = result.entries.map((entry) => entry.data).join("").trimEnd();
			const nextBlock = output.length > 0 ? `$ ${command}\n${output}` : `$ ${command}`;
			setTerminalOutput((current) => {
				const previous = current.trim() === "No terminal output yet." ? "" : current.trim();
				return previous.length > 0 ? `${previous}\n\n${nextBlock}` : nextBlock;
			});
			setTerminalInput("");
			setTimeout(() => {
				terminalScrollRef.current?.scrollToEnd({ animated: true });
			}, 0);
		} catch (error: unknown) {
			setTerminalError(error instanceof Error ? error.message : "Unable to run terminal command.");
		} finally {
			setIsTerminalRunning(false);
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : "height"}
			style={styles.root}
			testID="screen-chat"
		>
			<IosStackHeader
				backLabel="Menu"
				left={<MaterialIcons color={palette.text} name="menu" size={20} />}
				onBack={openDrawer}
				right={(
					<Pressable
						accessibilityLabel="chat-terminal-open-button"
						accessibilityRole="button"
						onPress={() => {
							setIsTerminalOpen(true);
						}}
						style={({ pressed }) => [styles.ghostButton, pressed ? styles.ghostButtonPressed : null]}
						testID="chat-terminal-open-button"
					>
						<MaterialIcons color={palette.text} name="terminal" size={20} />
					</Pressable>
				)}
				subtitle={selectedProject?.name ?? "No workspace selected"}
				title={selectedChat?.title ?? "Chat"}
			/>

			<View style={styles.body}>
				<ScrollView
					contentContainerStyle={styles.messagesContent}
					contentInsetAdjustmentBehavior="automatic"
					ref={messageScrollRef}
					showsVerticalScrollIndicator={false}
					style={styles.messages}
					testID="chat-message-list"
				>
					{messages.length === 0 && streamingText.trim().length === 0 ? (
						<Text style={styles.emptyState}>Start a conversation.</Text>
					) : null}

					{messages.map((message) => {
						const isUser = message.role === "user";
						return (
							<View key={message.id} style={[styles.messageRow, isUser ? styles.messageRowUser : null]}>
								<View style={[styles.messageBubble, isUser ? styles.userBubble : styles.assistantBubble]}>
									<MessageMarkdown
										content={message.content}
										textColor={palette.text}
										linkColor={palette.accent}
									/>
								</View>
							</View>
						);
					})}

					{streamingText.trim().length > 0 ? (
						<View style={styles.messageRow}>
							<View style={[styles.messageBubble, styles.assistantBubble]}>
								<MessageMarkdown content={streamingText} textColor={palette.text} linkColor={palette.accent} />
							</View>
						</View>
					) : null}

					{isSending && streamingText.trim().length === 0 ? (
						<Text style={styles.typingLabel}>Thinking...</Text>
					) : null}
				</ScrollView>

				{lastError ? (
					<Text selectable style={styles.errorText}>
						{lastError}
					</Text>
				) : null}

				<View style={styles.composerRow}>
					<TextInput
						autoCapitalize="sentences"
						multiline
						onChangeText={setInput}
						onSubmitEditing={() => {
							void submit();
						}}
						placeholder="Message"
						placeholderTextColor={palette.muted}
						style={styles.composerInput}
						testID="chat-input"
						value={input}
					/>

					<Pressable
						disabled={isSending || !selectedProjectId}
						onPress={() => {
							void submit();
						}}
						style={({ pressed }) => [
							styles.primaryAction,
							pressed ? styles.primaryActionPressed : null,
							isSending || !selectedProjectId ? styles.disabledButton : null,
						]}
						testID="chat-send-button"
					>
						<MaterialIcons
							color={styles.primaryActionLabel.color}
							name="send"
							size={20}
						/>
					</Pressable>
				</View>
			</View>

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
						</LinearGradient>
					</Animated.View>
				</View>
			</Modal>

			<Modal
				animationType="slide"
				onRequestClose={() => {
					setIsTerminalOpen(false);
				}}
				presentationStyle="fullScreen"
				visible={isTerminalOpen}
			>
				<KeyboardAvoidingView
					behavior={Platform.OS === "ios" ? "padding" : "height"}
					style={styles.terminalRoot}
					testID="terminal-modal"
				>
					<IosStackHeader
						onBack={() => {
							setIsTerminalOpen(false);
						}}
						right={(
							<Pressable
								onPress={() => {
									void createQuickChat();
								}}
								style={({ pressed }) => [styles.ghostButton, pressed ? styles.ghostButtonPressed : null]}
								testID="terminal-new-chat-button"
							>
								<Text style={styles.ghostLabel}>New Chat</Text>
							</Pressable>
						)}
						subtitle={selectedChat?.title ?? "No thread selected"}
						title="Terminal"
					/>

					<View style={styles.terminalBody}>
						<ScrollView
							contentContainerStyle={styles.terminalOutputContent}
							contentInsetAdjustmentBehavior="automatic"
							ref={terminalScrollRef}
							showsVerticalScrollIndicator={false}
							style={styles.terminalOutput}
						>
							{isTerminalLoading ? <Text style={styles.terminalMeta}>Loading history...</Text> : null}
							<Text selectable style={styles.terminalText}>
								{terminalOutput || "No terminal output yet."}
							</Text>
						</ScrollView>

						{terminalError.length > 0 ? (
							<Text selectable style={styles.errorText}>
								{terminalError}
							</Text>
						) : null}

						<View style={styles.terminalComposer}>
							<TextInput
								autoCapitalize="none"
								onChangeText={setTerminalInput}
								onSubmitEditing={() => {
									void runTerminalCommand();
								}}
								placeholder="Run command"
								placeholderTextColor={palette.muted}
								style={styles.composerInput}
								testID="terminal-command-input"
								value={terminalInput}
							/>
							<Pressable
								disabled={isTerminalRunning || !selectedChatId}
								onPress={() => {
									void runTerminalCommand();
								}}
								style={({ pressed }) => [
									styles.primaryAction,
									pressed ? styles.primaryActionPressed : null,
									isTerminalRunning || !selectedChatId ? styles.disabledButton : null,
								]}
								testID="terminal-run-button"
							>
								<Text style={styles.primaryActionLabel}>{isTerminalRunning ? "..." : "Run"}</Text>
							</Pressable>
						</View>
					</View>
				</KeyboardAvoidingView>
			</Modal>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	assistantBubble: {
		backgroundColor: palette.soft,
	},
	body: {
		flex: 1,
		paddingHorizontal: 12,
		paddingTop: 10,
	},
	composerInput: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 11,
		borderWidth: 1,
		color: palette.text,
		flex: 1,
		fontSize: 15,
		maxHeight: 120,
		minHeight: 42,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	composerRow: {
		alignItems: "flex-end",
		flexDirection: "row",
		gap: 8,
		paddingBottom: 12,
		paddingTop: 8,
	},
	disabledButton: {
		opacity: 0.45,
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
	emptyState: {
		color: palette.muted,
		fontSize: 14,
		paddingVertical: 20,
		textAlign: "center",
	},
	errorText: {
		color: "#FF8CA2",
		fontSize: 12,
		paddingBottom: 6,
	},
	ghostButton: {
		alignItems: "center",
		borderRadius: 10,
		height: 32,
		justifyContent: "center",
		paddingHorizontal: 10,
	},
	ghostButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	ghostLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	messageBubble: {
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		maxWidth: "92%",
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	messageRow: {
		flexDirection: "row",
		justifyContent: "flex-start",
	},
	messageRowUser: {
		justifyContent: "flex-end",
	},
	messageText: {
		color: palette.text,
		fontSize: 15,
		lineHeight: 21,
	},
	messages: {
		flex: 1,
	},
	messagesContent: {
		gap: 8,
		paddingBottom: 10,
	},
	primaryAction: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 11,
		height: 42,
		justifyContent: "center",
		minWidth: 62,
		paddingHorizontal: 12,
	},
	primaryActionLabel: {
		color: "#0A1D2B",
		fontSize: 13,
		fontWeight: "700",
	},
	primaryActionPressed: {
		backgroundColor: palette.accentPressed,
	},
	root: {
		backgroundColor: palette.background,
		flex: 1,
	},
	secondaryAction: {
		alignItems: "center",
		borderColor: palette.border,
		borderRadius: 11,
		borderWidth: 1,
		height: 42,
		justifyContent: "center",
		paddingHorizontal: 12,
	},
	secondaryActionLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	secondaryActionPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	terminalBody: {
		flex: 1,
		paddingHorizontal: 12,
		paddingTop: 12,
	},
	terminalComposer: {
		alignItems: "flex-end",
		flexDirection: "row",
		gap: 8,
		paddingBottom: 12,
		paddingTop: 8,
	},
	terminalMeta: {
		color: palette.muted,
		fontSize: 12,
		marginBottom: 8,
	},
	terminalOutput: {
		backgroundColor: "#0A0C10",
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		flex: 1,
	},
	terminalOutputContent: {
		padding: 12,
	},
	terminalRoot: {
		backgroundColor: palette.background,
		flex: 1,
	},
	terminalText: {
		color: palette.text,
		fontFamily: Platform.select({ ios: "Menlo", default: "monospace" }),
		fontSize: 13,
		lineHeight: 20,
	},
	typingLabel: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 4,
	},
	userBubble: {
		backgroundColor: palette.userBubble,
	},
});
