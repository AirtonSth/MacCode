import { LinearGradient } from "expo-linear-gradient";
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

import { useWorkspaceShell } from "@/features/chat/model/use-workspace-shell";
import { formatRelativeTime } from "@/shared/lib/time";
import { theme } from "@/shared/theme/tokens";
import { GhostButton } from "@/shared/ui/ghost-button";
import { GlassPanel } from "@/shared/ui/glass-panel";

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
		chats,
		connectionState,
		createChat,
		deleteChat,
		isLoaded,
		isSending,
		lastError,
		messages,
		projects,
		selectChat,
		selectProject,
		selectedChat,
		selectedChatId,
		selectedProjectId,
		sendMessage,
		streamingText,
		toggleFavorite,
	} = useWorkspaceShell();
	const [input, setInput] = useState<string>("");
	const dimensions = useWindowDimensions();
	const isWide = dimensions.width >= 960;
	const [isSidebarOpen, setIsSidebarOpen] = useState<boolean>(isWide);
	const messagesScrollRef = useRef<ScrollView | null>(null);
	const favoriteProjects = useMemo(
		() => projects.filter((project) => project.isFavorite),
		[projects],
	);

	useEffect(() => {
		setIsSidebarOpen(isWide);
	}, [isWide]);

	useEffect(() => {
		messagesScrollRef.current?.scrollToEnd({ animated: true });
	}, [messages.length, streamingText]);

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
										<Text
											selectable
											style={{
												color: theme.colors.textPrimary,
												fontSize: 14,
												lineHeight: 21,
											}}
										>
											{message.content}
										</Text>
									</View>
								</View>
							))}
							{streamingText.length > 0 ? (
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
										<Text
											selectable
											style={{
												color: theme.colors.textPrimary,
												fontSize: 14,
												lineHeight: 21,
											}}
										>
											{streamingText}
										</Text>
									</View>
								</View>
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
								<Text
									style={{
										color: theme.colors.textPrimary,
										fontSize: 13,
										fontWeight: "700",
									}}
								>
									{isSending ? "Sending" : "Send"}
								</Text>
							</Pressable>
						</View>
					</GlassPanel>
				</View>
			</View>
		</KeyboardAvoidingView>
	);
};
