import { LinearGradient } from "expo-linear-gradient";
import { MaterialIcons } from "@expo/vector-icons";
import { router } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import {
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	useWindowDimensions,
	View,
} from "react-native";

import { useRemoteCodeClient } from "../../../shared/api/use-remotecode-client";
import { formatRelativeTime } from "../../../shared/lib/time";
import { theme } from "../../../shared/theme/tokens";
import { GhostButton } from "../../../shared/ui/ghost-button";
import { GlassPanel } from "../../../shared/ui/glass-panel";
import { MessageMarkdown } from "../../../shared/ui/markdown-message";
import { useWorkspaceShell } from "../model/use-workspace-shell";
import { StreamingTimeline } from "./streaming-timeline";

const styles = StyleSheet.create({
	composerInput: {
		color: theme.colors.textPrimary,
		flex: 1,
		fontSize: 15,
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
});

export const WorkspaceScreen = () => {
	const {
		availableModels,
		chats,
		connectionState,
		createChat,
		createProject,
		deleteProject,
		deleteChat,
		isLoaded,
		isSending,
		lastError,
		messages,
		permissionMode,
		projects,
		selectedModel,
		selectedReasoningEffort,
		selectChat,
		selectProject,
		setPermissionMode,
		setSelectedModel,
		setSelectedReasoningEffort,
		setStreamItemExpanded,
		setStreamItemState,
		selectedChat,
		selectedChatId,
		selectedProjectId,
		sendMessage,
		streamingTurn,
		toggleFavorite,
	} = useWorkspaceShell();
	const [input, setInput] = useState<string>("");
	const [newProjectPath, setNewProjectPath] = useState<string>("");
	const [newProjectName, setNewProjectName] = useState<string>("");
	const [browserPath, setBrowserPath] = useState<string | null>(null);
	const [browserEntries, setBrowserEntries] = useState<
		{ name: string; path: string; type: "directory" | "file" }[]
	>([]);
	const [browserRoots, setBrowserRoots] = useState<{ id: string; label: string; path: string }[]>([]);
	const activeModel = useMemo(
		() => availableModels.find((item) => item.model === selectedModel) ?? null,
		[availableModels, selectedModel],
	);
	const api = useRemoteCodeClient();
	const [gitSummary, setGitSummary] = useState<string>("Git status unavailable");
	const [gitBranchInput, setGitBranchInput] = useState<string>("");
	const [gitCommitMessage, setGitCommitMessage] = useState<string>("");
	const [terminalInput, setTerminalInput] = useState<string>("");
	const [terminalOutput, setTerminalOutput] = useState<string>("");
	const dimensions = useWindowDimensions();
	const isWide = dimensions.width >= 960;
	const [isSidebarOpen, setIsSidebarOpen] = useState<boolean>(isWide);
	const messagesScrollRef = useRef<ScrollView | null>(null);
	const favoriteProjects = useMemo(
		() => projects.filter((project) => project.isFavorite),
		[projects],
	);
	const hasStreamingItems = Boolean(streamingTurn && streamingTurn.itemOrder.length > 0);

	useEffect(() => {
		setIsSidebarOpen(isWide);
	}, [isWide]);

	useEffect(() => {
		messagesScrollRef.current?.scrollToEnd({ animated: true });
	}, [messages.length, streamingTurn]);

	const handleSend = async () => {
		const text = input.trim();

		if (text.length === 0) {
			return;
		}

		const sent = await sendMessage(text);
		if (sent) {
			setInput("");
		}
	};

	const handleCreateProject = async () => {
		const path = newProjectPath.trim();
		if (!path) {
			return;
		}

		await createProject({
			name: newProjectName.trim() || undefined,
			path,
		});
		setNewProjectName("");
		setNewProjectPath("");
	};

	const loadRoots = async () => {
		const roots = await api.listFsRoots();
		setBrowserRoots(roots);
	};

	const loadDirectory = async (path: string) => {
		const listed = await api.listFsEntries(path);
		setBrowserPath(listed.path);
		setBrowserEntries(listed.entries);
	};

	const handleRefreshGit = async () => {
		if (!selectedProjectId) {
			return;
		}

		const status = await api.getProjectGitStatus(selectedProjectId);
		setGitSummary(
			status.isRepo
				? `branch=${status.currentBranch ?? "detached"} · +${String(status.added)} / -${String(status.removed)} · changed=${String(status.changedFiles)}`
				: "Project is not a git repository",
		);
	};

	const handleCreateBranch = async () => {
		if (!selectedProjectId || gitBranchInput.trim().length === 0) {
			return;
		}

		await api.createProjectGitBranch(selectedProjectId, gitBranchInput.trim());
		setGitBranchInput("");
		await handleRefreshGit();
	};

	const handleCheckoutBranch = async () => {
		if (!selectedProjectId || gitBranchInput.trim().length === 0) {
			return;
		}

		await api.checkoutProjectGitBranch(selectedProjectId, gitBranchInput.trim());
		setGitBranchInput("");
		await handleRefreshGit();
	};

	const handleCommit = async () => {
		if (!selectedProjectId) {
			return;
		}

		await api.commitProject(selectedProjectId, {
			message: gitCommitMessage,
			includeUnstaged: true,
			push: false,
		});
		await handleRefreshGit();
	};

	const handleTerminalRun = async () => {
		const command = terminalInput.trim();
		if (!selectedChatId || command.length === 0) {
			return;
		}

		const result = await api.execTerminalCommand(selectedChatId, { command });
		const transcript = result.entries.map((entry) => `[${entry.stream}] ${entry.data}`).join("");
		setTerminalOutput((current) => `${current}\\n$ ${command}\\n${transcript}`.trim());
		setTerminalInput("");
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : "height"}
			style={{
				backgroundColor: theme.colors.background,
				flex: 1,
			}}
		>
			<LinearGradient
				colors={[
					"rgba(55,150,255,0.22)",
					"rgba(246,98,168,0.12)",
					"rgba(13,15,20,0.96)",
				]}
				end={{ x: 0.85, y: 1 }}
				start={{ x: 0.1, y: 0 }}
				style={{
					bottom: 0,
					left: 0,
					position: "absolute",
					right: 0,
					top: 0,
				}}
			/>

			<View
				style={{
					flex: 1,
					paddingBottom: 14,
					paddingHorizontal: 12,
					paddingTop: 56,
				}}
			>
				<View
					style={{
						alignItems: "center",
						flexDirection: "row",
						justifyContent: "space-between",
						marginBottom: 10,
					}}
				>
					<View
						style={{
							alignItems: "center",
							flexDirection: "row",
							gap: 8,
						}}
					>
						<GhostButton
							label={isSidebarOpen ? "Hide Threads" : "Show Threads"}
							onPress={() => {
								setIsSidebarOpen((current) => !current);
							}}
						/>
						<Text
							style={{
								color: theme.colors.textSecondary,
								fontSize: 12,
								fontWeight: "600",
								textTransform: "uppercase",
							}}
						>
							{connectionState}
						</Text>
					</View>
					<GhostButton
						label="Settings"
						onPress={() => {
							router.push("/settings");
						}}
					/>
				</View>

				<View
					style={{
						flex: 1,
						flexDirection: isWide ? "row" : "column",
						gap: 10,
					}}
				>
					{isSidebarOpen ? (
						<LinearGradient
							colors={[theme.colors.sidebarTop, theme.colors.sidebarBottom]}
							style={{
								borderColor: theme.colors.borderSoft,
								borderRadius: theme.borderRadius.panel,
								borderWidth: 1,
								minHeight: isWide ? undefined : 300,
								padding: 12,
								width: isWide ? 320 : undefined,
							}}
						>
							<ScrollView contentInsetAdjustmentBehavior="automatic">
								<View
									style={{
										gap: 14,
									}}
								>
									<View>
										<Text
											style={{
												color: theme.colors.textSecondary,
												fontSize: 12,
												letterSpacing: 0.8,
												marginBottom: 8,
												textTransform: "uppercase",
											}}
										>
											Favorites
										</Text>
										{favoriteProjects.length === 0 ? (
											<Text
												style={{
													color: theme.colors.muted,
													fontSize: 13,
												}}
											>
												No favorite projects yet.
											</Text>
										) : null}
										{favoriteProjects.map((project) => (
											<Pressable
												key={project.id}
												onPress={() => {
													selectProject(project);
												}}
												style={({ pressed }) => ({
													backgroundColor: pressed || project.id === selectedProjectId
														? "rgba(255,255,255,0.12)"
														: "rgba(255,255,255,0.04)",
													borderColor: theme.colors.borderSoft,
													borderRadius: theme.borderRadius.card,
													borderWidth: 1,
													marginBottom: 8,
													paddingHorizontal: 12,
													paddingVertical: 10,
												})}
											>
												<View
													style={{
														alignItems: "center",
														flexDirection: "row",
														justifyContent: "space-between",
													}}
												>
													<Text
														numberOfLines={1}
														style={{
															color: theme.colors.textPrimary,
															flex: 1,
															fontSize: 14,
															fontWeight: "700",
														}}
													>
														{project.name}
													</Text>
													<Pressable
														onPress={() => {
															void toggleFavorite(project);
														}}
													>
														<Text style={{ color: theme.colors.warn }}>★</Text>
													</Pressable>
												</View>
											</Pressable>
										))}
									</View>

									<View>
										<Text
											style={{
												color: theme.colors.textSecondary,
												fontSize: 12,
												letterSpacing: 0.8,
												marginBottom: 8,
												textTransform: "uppercase",
											}}
										>
											Projects
										</Text>
										<View style={{ gap: 6, marginBottom: 10 }}>
											<TextInput
												autoCapitalize="none"
												onChangeText={setNewProjectPath}
												placeholder="Add project path (absolute)"
												placeholderTextColor={theme.colors.muted}
												style={{
													backgroundColor: "rgba(255,255,255,0.04)",
													borderColor: theme.colors.borderSoft,
													borderRadius: theme.borderRadius.chip,
													borderWidth: 1,
													color: theme.colors.textPrimary,
													fontSize: 12,
													paddingHorizontal: 10,
													paddingVertical: 7,
												}}
												value={newProjectPath}
											/>
											<TextInput
												autoCapitalize="none"
												onChangeText={setNewProjectName}
												placeholder="Optional project name"
												placeholderTextColor={theme.colors.muted}
												style={{
													backgroundColor: "rgba(255,255,255,0.04)",
													borderColor: theme.colors.borderSoft,
													borderRadius: theme.borderRadius.chip,
													borderWidth: 1,
													color: theme.colors.textPrimary,
													fontSize: 12,
													paddingHorizontal: 10,
													paddingVertical: 7,
												}}
												value={newProjectName}
											/>
											<GhostButton
												label="Create Project"
												onPress={() => {
													void handleCreateProject();
												}}
											/>
											<GhostButton
												label="Browse Remote FS"
												onPress={() => {
													void loadRoots();
												}}
											/>
											{browserRoots.length > 0 ? (
												<View style={{ gap: 4 }}>
													<Text style={{ color: theme.colors.muted, fontSize: 12 }}>Roots</Text>
													{browserRoots.map((root) => (
														<Pressable
															key={root.id}
															onPress={() => {
																void loadDirectory(root.path);
															}}
														>
															<Text style={{ color: theme.colors.textSecondary, fontSize: 12 }}>{root.label}</Text>
														</Pressable>
													))}
												</View>
											) : null}
											{browserPath ? (
												<View style={{ gap: 4 }}>
													<Text style={{ color: theme.colors.muted, fontSize: 12 }}>
														{`Path: ${browserPath}`}
													</Text>
													{browserEntries.slice(0, 24).map((entry) => (
														<Pressable
															key={entry.path}
															onPress={() => {
																if (entry.type === "directory") {
																	setNewProjectPath(entry.path);
																	void loadDirectory(entry.path);
																} else {
																	setNewProjectPath(entry.path);
																}
															}}
														>
															<Text style={{ color: theme.colors.textSecondary, fontSize: 12 }}>
																{entry.type === "directory" ? "[DIR]" : "[FILE]"} {entry.name}
															</Text>
														</Pressable>
													))}
												</View>
											) : null}
										</View>
										{projects.map((project) => (
											<Pressable
												key={project.id}
												onPress={() => {
													selectProject(project);
												}}
												style={({ pressed }) => ({
													backgroundColor: pressed || project.id === selectedProjectId
														? "rgba(255,255,255,0.12)"
														: "transparent",
													borderRadius: theme.borderRadius.chip,
													marginBottom: 4,
													paddingHorizontal: 8,
													paddingVertical: 7,
												})}
											>
												<View
													style={{
														alignItems: "center",
														flexDirection: "row",
														justifyContent: "space-between",
													}}
												>
													<Text
														numberOfLines={1}
														style={{
															color: theme.colors.textPrimary,
															flex: 1,
															fontSize: 14,
															fontWeight: "600",
														}}
													>
														{project.name}
													</Text>
													<Pressable
														onPress={() => {
															void toggleFavorite(project);
														}}
													>
														<Text
															style={{
																color: project.isFavorite ? theme.colors.warn : theme.colors.muted,
															}}
														>
															★
														</Text>
													</Pressable>
													<Pressable
														onPress={() => {
															void deleteProject(project.id);
														}}
														style={{ marginLeft: 8 }}
													>
														<Text style={{ color: theme.colors.danger }}>×</Text>
													</Pressable>
												</View>
											</Pressable>
										))}
									</View>

									<View>
										<View
											style={{
												alignItems: "center",
												flexDirection: "row",
												justifyContent: "space-between",
												marginBottom: 8,
											}}
										>
											<Text
												style={{
													color: theme.colors.textSecondary,
													fontSize: 12,
													letterSpacing: 0.8,
													textTransform: "uppercase",
												}}
											>
												Recent Chats
											</Text>
											<GhostButton
												label="New"
												onPress={() => {
													void createChat("New thread");
												}}
											/>
										</View>
										{chats.map((chat) => (
											<Pressable
												key={chat.id}
												onPress={() => {
													selectChat(chat);
												}}
												style={({ pressed }) => ({
													backgroundColor: pressed || chat.id === selectedChatId
														? "rgba(255,255,255,0.12)"
														: "transparent",
													borderRadius: theme.borderRadius.chip,
													marginBottom: 4,
													paddingHorizontal: 8,
													paddingVertical: 7,
												})}
											>
												<View
													style={{
														alignItems: "center",
														flexDirection: "row",
														gap: 8,
													}}
												>
													<Text
														numberOfLines={1}
														style={{
															color: theme.colors.textPrimary,
															flex: 1,
															fontSize: 13,
														}}
													>
														{chat.title}
													</Text>
													<Text
														style={{
															color: theme.colors.muted,
															fontSize: 12,
														}}
													>
														{formatRelativeTime(chat.updatedAt)}
													</Text>
													<Pressable
														onPress={() => {
															void deleteChat(chat.id);
														}}
													>
														<Text style={{ color: theme.colors.danger }}>×</Text>
													</Pressable>
												</View>
											</Pressable>
										))}
									</View>
								</View>
							</ScrollView>
						</LinearGradient>
					) : null}

					<GlassPanel
						style={{
							flex: 1,
							paddingBottom: 10,
							paddingTop: 10,
						}}
					>
						<View
							style={{
								borderBottomColor: theme.colors.borderSoft,
								borderBottomWidth: 1,
								marginBottom: 10,
								paddingBottom: 8,
							}}
						>
							<Text
								numberOfLines={1}
								style={{
									color: theme.colors.textPrimary,
									fontSize: 20,
									fontWeight: "700",
								}}
							>
								{selectedChat?.title ?? "Select a thread"}
							</Text>
							<Text
								style={{
									color: theme.colors.textSecondary,
									fontSize: 12,
									marginTop: 4,
								}}
							>
								{selectedChat ? `${selectedChat.provider} · ${selectedChat.status}` : "Waiting for a chat selection"}
							</Text>
							<View style={{ gap: 8, marginTop: 10 }}>
								<View
									style={{
										alignItems: "center",
										flexDirection: "row",
										gap: 8,
									}}
								>
									<Text style={{ color: theme.colors.textSecondary, fontSize: 12, width: 84 }}>Model</Text>
									<TextInput
										autoCapitalize="none"
										onChangeText={setSelectedModel}
										placeholder="codex model"
										placeholderTextColor={theme.colors.muted}
										style={{
											backgroundColor: "rgba(255,255,255,0.04)",
											borderColor: theme.colors.borderSoft,
											borderRadius: theme.borderRadius.chip,
											borderWidth: 1,
											color: theme.colors.textPrimary,
											flex: 1,
											fontSize: 12,
											paddingHorizontal: 10,
											paddingVertical: 7,
										}}
										value={selectedModel ?? ""}
									/>
								</View>
								<View
									style={{
										alignItems: "center",
										flexDirection: "row",
										gap: 8,
									}}
								>
									<Text style={{ color: theme.colors.textSecondary, fontSize: 12, width: 84 }}>Permission</Text>
									<TextInput
										autoCapitalize="none"
										onChangeText={setPermissionMode}
										placeholder="plan | default | full"
										placeholderTextColor={theme.colors.muted}
										style={{
											backgroundColor: "rgba(255,255,255,0.04)",
											borderColor: theme.colors.borderSoft,
											borderRadius: theme.borderRadius.chip,
											borderWidth: 1,
											color: theme.colors.textPrimary,
											flex: 1,
											fontSize: 12,
											paddingHorizontal: 10,
											paddingVertical: 7,
										}}
										value={permissionMode}
									/>
								</View>
								<View
									style={{
										alignItems: "center",
										flexDirection: "row",
										gap: 8,
									}}
								>
									<Text style={{ color: theme.colors.textSecondary, fontSize: 12, width: 84 }}>Reasoning</Text>
									<TextInput
										autoCapitalize="none"
										onChangeText={setSelectedReasoningEffort}
										placeholder="minimal | medium | high"
										placeholderTextColor={theme.colors.muted}
										style={{
											backgroundColor: "rgba(255,255,255,0.04)",
											borderColor: theme.colors.borderSoft,
											borderRadius: theme.borderRadius.chip,
											borderWidth: 1,
											color: theme.colors.textPrimary,
											flex: 1,
											fontSize: 12,
											paddingHorizontal: 10,
											paddingVertical: 7,
										}}
										value={selectedReasoningEffort ?? ""}
									/>
								</View>
								{activeModel ? (
									<Text style={{ color: theme.colors.muted, fontSize: 11 }}>
										Available reasoning: {activeModel.supportedReasoningEfforts.map((item) => item.reasoningEffort).join(", ")}
									</Text>
								) : null}
							</View>
						</View>

						<ScrollView
							contentInsetAdjustmentBehavior="automatic"
							ref={messagesScrollRef}
							style={{ flex: 1 }}
						>
							{!isLoaded ? (
								<Text style={{ color: theme.colors.textSecondary }}>Loading workspace...</Text>
							) : null}
							{messages.map((message) => (
								<View
									key={message.id}
									style={{
										alignItems: message.role === "user" ? "flex-end" : "flex-start",
										marginBottom: 10,
									}}
								>
									<View
										style={{
											backgroundColor: message.role === "user"
												? theme.colors.chatBubbleUser
												: theme.colors.chatBubbleAssistant,
											borderColor: theme.colors.borderSoft,
											borderRadius: theme.borderRadius.card,
											borderWidth: 1,
											maxWidth: "92%",
											paddingHorizontal: 12,
											paddingVertical: 10,
										}}
									>
										<MessageMarkdown
											content={message.content}
											linkColor={theme.colors.accent}
											textColor={theme.colors.textPrimary}
										/>
									</View>
								</View>
							))}
							{hasStreamingItems && streamingTurn ? (
								<View
									style={{
										alignItems: "flex-start",
										marginBottom: 12,
									}}
								>
									<View
										style={{
											backgroundColor: "rgba(255,255,255,0.08)",
											borderColor: theme.colors.borderSoft,
											borderRadius: theme.borderRadius.card,
											borderWidth: 1,
											paddingHorizontal: 12,
											paddingVertical: 10,
										}}
									>
										<StreamingTimeline
											onSetItemExpanded={(itemId, expanded, byUser) => {
												setStreamItemExpanded(itemId, expanded, byUser);
											}}
											onSetItemState={(itemId, state) => {
												setStreamItemState(itemId, state);
											}}
											turn={streamingTurn}
										/>
									</View>
								</View>
							) : null}
							{isSending && !hasStreamingItems ? (
								<Text style={{ color: theme.colors.muted, fontSize: 12, marginBottom: 12 }}>
									Thinking...
								</Text>
							) : null}
						</ScrollView>

						{lastError ? (
							<Text
								selectable
								style={{
									color: theme.colors.danger,
									fontSize: 13,
									marginBottom: 8,
									marginTop: 8,
								}}
							>
								{lastError}
							</Text>
						) : null}

						<View
							style={{
								alignItems: "center",
								borderColor: theme.colors.borderSoft,
								borderRadius: theme.borderRadius.composer,
								borderWidth: 1,
								flexDirection: "row",
								gap: 8,
								marginTop: 10,
								padding: 6,
							}}
						>
							<TextInput
								autoCapitalize="sentences"
								onChangeText={setInput}
								onSubmitEditing={() => {
									void handleSend();
								}}
								placeholder="Write a message..."
								placeholderTextColor={theme.colors.muted}
								style={styles.composerInput}
								value={input}
							/>
							<Pressable
								disabled={isSending || selectedProjectId === null}
								onPress={() => {
									void handleSend();
								}}
								style={({ pressed }) => ({
									backgroundColor: pressed ? "rgba(99,200,255,0.25)" : "rgba(99,200,255,0.18)",
									borderColor: "rgba(99,200,255,0.35)",
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
								opacity: isSending ? 0.65 : 1,
									paddingHorizontal: 14,
									paddingVertical: 10,
								})}
							>
								<MaterialIcons color={theme.colors.textPrimary} name="send" size={18} />
							</Pressable>
						</View>

						<View
							style={{
								borderColor: theme.colors.borderSoft,
								borderRadius: theme.borderRadius.card,
								borderWidth: 1,
								gap: 8,
								marginTop: 10,
								padding: 10,
							}}
						>
							<Text style={{ color: theme.colors.textPrimary, fontSize: 14, fontWeight: "700" }}>
								Git Controls
							</Text>
							<Text selectable style={{ color: theme.colors.muted, fontSize: 12 }}>
								{gitSummary}
							</Text>
							<View style={{ flexDirection: "row", gap: 8 }}>
								<GhostButton
									label="Refresh Git"
									onPress={() => {
										void handleRefreshGit();
									}}
								/>
							</View>
							<TextInput
								autoCapitalize="none"
								onChangeText={setGitBranchInput}
								placeholder="Branch name"
								placeholderTextColor={theme.colors.muted}
								style={{
									backgroundColor: "rgba(255,255,255,0.04)",
									borderColor: theme.colors.borderSoft,
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
									color: theme.colors.textPrimary,
									fontSize: 12,
									paddingHorizontal: 10,
									paddingVertical: 8,
								}}
								value={gitBranchInput}
							/>
							<View style={{ flexDirection: "row", gap: 8 }}>
								<GhostButton
									label="Create Branch"
									onPress={() => {
										void handleCreateBranch();
									}}
								/>
								<GhostButton
									label="Checkout"
									onPress={() => {
										void handleCheckoutBranch();
									}}
								/>
							</View>
							<TextInput
								onChangeText={setGitCommitMessage}
								placeholder="Commit message"
								placeholderTextColor={theme.colors.muted}
								style={{
									backgroundColor: "rgba(255,255,255,0.04)",
									borderColor: theme.colors.borderSoft,
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
									color: theme.colors.textPrimary,
									fontSize: 12,
									paddingHorizontal: 10,
									paddingVertical: 8,
								}}
								value={gitCommitMessage}
							/>
							<GhostButton
								label="Commit"
								onPress={() => {
									void handleCommit();
								}}
							/>
						</View>

						<View
							style={{
								borderColor: theme.colors.borderSoft,
								borderRadius: theme.borderRadius.card,
								borderWidth: 1,
								gap: 8,
								marginTop: 10,
								padding: 10,
							}}
						>
							<Text style={{ color: theme.colors.textPrimary, fontSize: 14, fontWeight: "700" }}>
								Terminal
							</Text>
							<TextInput
								autoCapitalize="none"
								onChangeText={setTerminalInput}
								placeholder="Run command"
								placeholderTextColor={theme.colors.muted}
								style={{
									backgroundColor: "rgba(255,255,255,0.04)",
									borderColor: theme.colors.borderSoft,
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
									color: theme.colors.textPrimary,
									fontSize: 12,
									paddingHorizontal: 10,
									paddingVertical: 8,
								}}
								value={terminalInput}
							/>
							<GhostButton
								label="Run Command"
								onPress={() => {
									void handleTerminalRun();
								}}
							/>
							<Text selectable style={{ color: theme.colors.muted, fontSize: 12 }}>
								{terminalOutput.length > 0 ? terminalOutput : "No terminal output yet."}
							</Text>
						</View>
					</GlassPanel>
				</View>
			</View>
		</KeyboardAvoidingView>
	);
};
