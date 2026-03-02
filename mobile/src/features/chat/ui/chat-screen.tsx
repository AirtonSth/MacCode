import { LinearGradient } from "expo-linear-gradient";
import { useRouter } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import {
	KeyboardAvoidingView,
	Platform,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";

import { useWorkspaceShell } from "../model/use-workspace-shell";

const suggestionPrompts = [
	"Summarize the latest code changes in this workspace.",
	"Create a quick implementation plan for my next task.",
	"Find potential bugs and suggest focused fixes.",
	"Draft a clean commit message for my current edits.",
];

const palette = {
	accent: "#6DE3C2",
	accentPressed: "#53C9AB",
	background: "#050A15",
	card: "rgba(11, 24, 45, 0.86)",
	cardSoft: "rgba(10, 18, 34, 0.7)",
	line: "rgba(255, 255, 255, 0.12)",
	muted: "#93A6C7",
	text: "#F3F7FF",
	userBubble: "rgba(109, 227, 194, 0.22)",
};

export const ChatScreen = () => {
	const router = useRouter();
	const {
		connectionState,
		isLoaded,
		isSending,
		lastError,
		messages,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage,
		streamingText,
	} = useWorkspaceShell();
	const [input, setInput] = useState<string>("");
	const scrollRef = useRef<ScrollView | null>(null);

	useEffect(() => {
		scrollRef.current?.scrollToEnd({ animated: true });
	}, [messages.length, streamingText]);

	const showSuggestions = useMemo(
		() => isLoaded && messages.length === 0 && streamingText.trim().length === 0,
		[isLoaded, messages.length, streamingText],
	);

	const submit = async (rawText: string) => {
		const text = rawText.trim();
		if (!text) {
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
			style={styles.root}
		>
			<LinearGradient
				colors={["#1A2B50", "#0E1A35", palette.background]}
				end={{ x: 0.9, y: 1 }}
				start={{ x: 0.1, y: 0 }}
				style={StyleSheet.absoluteFill}
			/>

			<View style={styles.screen}>
				<Text style={styles.stepLabel}>STEP 4 OF 4</Text>
				<View style={styles.progressRow}>
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={[styles.progressDot, styles.progressDotActive]} />
				</View>

				<View style={styles.topActions}>
					<Pressable
						onPress={() => {
							router.push("/threads");
						}}
						style={({ pressed }) => [
							styles.secondaryButton,
							pressed ? styles.secondaryButtonPressed : null,
						]}
					>
						<Text style={styles.secondaryButtonLabel}>Threads</Text>
					</Pressable>
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

				<View style={styles.chatHeader}>
					<Text numberOfLines={1} style={styles.chatTitle}>
						{selectedChat?.title ?? "Select a thread"}
					</Text>
					<Text numberOfLines={1} style={styles.chatSubtitle}>
						{selectedProject ? `${selectedProject.name} · ${connectionState}` : connectionState}
					</Text>
				</View>

				<View style={styles.chatCard}>
					<ScrollView
						contentContainerStyle={styles.messagesContent}
						contentInsetAdjustmentBehavior="automatic"
						ref={scrollRef}
						showsVerticalScrollIndicator={false}
						style={styles.messagesContainer}
					>
						{!selectedProjectId || !selectedChatId ? (
							<View style={styles.placeholderBox}>
								<Text style={styles.placeholderTitle}>Thread required</Text>
								<Text style={styles.placeholderText}>
									Choose or create a thread to start chatting with Codex.
								</Text>
								<Pressable
									onPress={() => {
										router.push("/threads");
									}}
									style={({ pressed }) => [
										styles.primaryButton,
										pressed ? styles.primaryButtonPressed : null,
									]}
								>
									<Text style={styles.primaryButtonLabel}>Go to threads</Text>
								</Pressable>
							</View>
						) : null}

						{messages.map((message) => {
							const isUser = message.role === "user";
							return (
								<View
									key={message.id}
									style={[
										styles.messageRow,
										isUser ? styles.messageRowUser : styles.messageRowAssistant,
									]}
								>
									<View
										style={[
											styles.messageBubble,
											isUser ? styles.userBubble : styles.assistantBubble,
										]}
									>
										<Text selectable style={styles.messageText}>
											{message.content}
										</Text>
									</View>
								</View>
							);
						})}

						{streamingText.length > 0 ? (
							<View style={[styles.messageRow, styles.messageRowAssistant]}>
								<View style={[styles.messageBubble, styles.assistantBubble]}>
									<Text selectable style={styles.messageText}>
										{streamingText}
									</Text>
								</View>
							</View>
						) : null}

						{isSending && streamingText.length === 0 ? (
							<View style={[styles.messageRow, styles.messageRowAssistant]}>
								<View style={[styles.messageBubble, styles.assistantBubble]}>
									<Text style={styles.typingText}>Codex is thinking...</Text>
								</View>
							</View>
						) : null}

						{showSuggestions ? (
							<View style={styles.suggestionsSection}>
								<Text style={styles.suggestionsTitle}>Try one of these</Text>
								{suggestionPrompts.map((prompt) => (
									<Pressable
										key={prompt}
										onPress={() => {
											void submit(prompt);
										}}
										style={({ pressed }) => [
											styles.suggestionCard,
											pressed ? styles.suggestionCardPressed : null,
										]}
									>
										<Text style={styles.suggestionText}>{prompt}</Text>
									</Pressable>
								))}
							</View>
						) : null}
					</ScrollView>

					{lastError ? <Text style={styles.errorText}>{lastError}</Text> : null}

					<View style={styles.composer}>
						<TextInput
							autoCapitalize="sentences"
							multiline
							onChangeText={setInput}
							onSubmitEditing={() => {
								void submit(input);
							}}
							placeholder="Ask Codex anything..."
							placeholderTextColor={palette.muted}
							style={styles.composerInput}
							value={input}
						/>
						<Pressable
							disabled={isSending || !selectedProjectId}
							onPress={() => {
								void submit(input);
							}}
							style={({ pressed }) => [
								styles.primaryButton,
								styles.sendButton,
								pressed ? styles.primaryButtonPressed : null,
								isSending || !selectedProjectId ? styles.disabledButton : null,
							]}
						>
							<Text style={styles.primaryButtonLabel}>{isSending ? "Sending..." : "Send"}</Text>
						</Pressable>
					</View>
				</View>
			</View>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	assistantBubble: {
		backgroundColor: palette.cardSoft,
	},
	chatCard: {
		backgroundColor: palette.card,
		borderColor: palette.line,
		borderRadius: 20,
		borderWidth: 1,
		flex: 1,
		padding: 12,
	},
	chatHeader: {
		gap: 4,
	},
	chatSubtitle: {
		color: palette.muted,
		fontSize: 13,
	},
	chatTitle: {
		color: palette.text,
		fontSize: 26,
		fontWeight: "800",
	},
	composer: {
		alignItems: "flex-end",
		borderColor: palette.line,
		borderRadius: 16,
		borderWidth: 1,
		flexDirection: "row",
		gap: 10,
		marginTop: 10,
		padding: 8,
	},
	composerInput: {
		color: palette.text,
		flex: 1,
		fontSize: 15,
		maxHeight: 130,
		minHeight: 44,
		paddingHorizontal: 10,
		paddingVertical: 8,
	},
	disabledButton: {
		opacity: 0.45,
	},
	errorText: {
		color: "#FF7685",
		fontSize: 12,
		marginTop: 8,
	},
	messageBubble: {
		borderColor: palette.line,
		borderRadius: 16,
		borderWidth: 1,
		maxWidth: "88%",
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	messageRow: {
		marginBottom: 10,
	},
	messageRowAssistant: {
		alignItems: "flex-start",
	},
	messageRowUser: {
		alignItems: "flex-end",
	},
	messageText: {
		color: palette.text,
		fontSize: 15,
		lineHeight: 22,
	},
	messagesContainer: {
		flex: 1,
	},
	messagesContent: {
		paddingBottom: 6,
	},
	placeholderBox: {
		alignItems: "center",
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 16,
		borderWidth: 1,
		gap: 8,
		marginBottom: 14,
		padding: 16,
	},
	placeholderText: {
		color: palette.muted,
		fontSize: 14,
		lineHeight: 20,
		textAlign: "center",
	},
	placeholderTitle: {
		color: palette.text,
		fontSize: 16,
		fontWeight: "700",
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 14,
		justifyContent: "center",
		minHeight: 44,
		paddingHorizontal: 14,
	},
	primaryButtonLabel: {
		color: "#062016",
		fontSize: 14,
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
	screen: {
		flex: 1,
		gap: 12,
		paddingBottom: 12,
		paddingHorizontal: 14,
		paddingTop: 54,
	},
	secondaryButton: {
		alignItems: "center",
		borderColor: palette.line,
		borderRadius: 12,
		borderWidth: 1,
		flex: 1,
		justifyContent: "center",
		minHeight: 40,
		paddingHorizontal: 10,
	},
	secondaryButtonLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	secondaryButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	sendButton: {
		minWidth: 88,
	},
	stepLabel: {
		color: palette.muted,
		fontSize: 11,
		fontWeight: "700",
		letterSpacing: 1.2,
	},
	suggestionCard: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		marginTop: 8,
		minHeight: 52,
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	suggestionCardPressed: {
		backgroundColor: "rgba(255,255,255,0.12)",
	},
	suggestionText: {
		color: palette.text,
		fontSize: 14,
		lineHeight: 19,
	},
	suggestionsSection: {
		marginBottom: 8,
		marginTop: 4,
	},
	suggestionsTitle: {
		color: palette.muted,
		fontSize: 12,
		fontWeight: "700",
		letterSpacing: 0.4,
		textTransform: "uppercase",
	},
	topActions: {
		flexDirection: "row",
		gap: 8,
	},
	typingText: {
		color: palette.muted,
		fontSize: 14,
		fontStyle: "italic",
	},
	userBubble: {
		backgroundColor: palette.userBubble,
	},
});
