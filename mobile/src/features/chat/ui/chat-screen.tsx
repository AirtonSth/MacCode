import { useQuery, useQueryClient } from "@tanstack/react-query";
import { MaterialIcons } from "@expo/vector-icons";
import { LinearGradient } from "expo-linear-gradient";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useLocalSearchParams } from "expo-router";
import {
	Animated,
	Keyboard,
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
import { appendAttachmentPathsToMessage } from "../model/attachment-paths";
import { StreamingTimeline } from "./streamingTimeline";
import { DesktopFilePickerModal } from "./desktop-file-picker-modal";
import { useApiConfig } from "../../../shared/api/api-config-provider";
import { useFlowNavigator } from "../../../shared/navigation/use-flow-navigator";
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

type ActivePicker = "branch" | "model" | "permission" | "reasoning";

const getSelectModalTitle = (activePicker: ActivePicker | null): string => {
	switch (activePicker) {
		case "branch": {
			return "Select branch";
		}
		case "model": {
			return "Select model";
		}
		case null: {
			return "Select branch";
		}
		case "permission": {
			return "Select permission";
		}
		case "reasoning": {
			return "Select reasoning";
		}
		default: {
			return "Select branch";
		}
	}
	return "Select branch";
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
	const { source } = useLocalSearchParams<{ source?: string }>();
	const api = useRemoteCodeClient();
	const { replace } = useFlowNavigator();
	const { config, isLoaded: isConfigLoaded } = useApiConfig();
	const {
		createChat,
		availableModels,
		isLoaded,
		isSending,
		lastError,
		selectedModel,
		messages,
		projects,
		permissionMode,
		setStreamItemExpanded,
		setStreamItemState,
		setSelectedModel,
		setSelectedReasoningEffort,
		setPermissionMode,
		selectProject,
		selectedChat,
		selectedChatId,
		selectedProject,
		selectedProjectId,
		sendMessage,
		selectedReasoningEffort,
		streamingTurn,
	} = useWorkspaceShell();
	const [input, setInput] = useState<string>("");
	const [drawerSearchValue, setDrawerSearchValue] = useState<string>("");
	const [activePicker, setActivePicker] = useState<ActivePicker | null>(null);
	const [isDrawerOpen, setIsDrawerOpen] = useState<boolean>(false);
	const [isTerminalOpen, setIsTerminalOpen] = useState<boolean>(false);
	const [isFilePickerOpen, setIsFilePickerOpen] = useState<boolean>(false);
	const [isKeyboardVisible, setIsKeyboardVisible] = useState<boolean>(false);
	const [isBranchCheckoutPending, setIsBranchCheckoutPending] = useState<boolean>(false);
	const selectorsScrollRef = useRef<ScrollView | null>(null);
	const [terminalInput, setTerminalInput] = useState<string>("");
	const [terminalOutput, setTerminalOutput] = useState<string>("");
	const [terminalError, setTerminalError] = useState<string>("");
	const [isTerminalLoading, setIsTerminalLoading] = useState<boolean>(false);
	const [isTerminalRunning, setIsTerminalRunning] = useState<boolean>(false);
	const queryClient = useQueryClient();
	const messageScrollRef = useRef<ScrollView | null>(null);
	const terminalScrollRef = useRef<ScrollView | null>(null);
	const drawerTranslate = useRef<Animated.Value>(new Animated.Value(-drawerWidth)).current;
	const drawerOpacity = useRef<Animated.Value>(new Animated.Value(0)).current;
	const gitStatusQuery = useQuery({
		enabled: Boolean(selectedProjectId),
		queryKey: ["project-git-status", selectedProjectId],
		queryFn: async () => {
			if (!selectedProjectId) {
				return null;
			}

			return await api.getProjectGitStatus(selectedProjectId);
		},
		staleTime: 30_000,
	});
	const gitBranchesQuery = useQuery({
		enabled: Boolean(selectedProjectId),
		queryKey: ["project-git-branches", selectedProjectId],
		queryFn: async () => {
			if (!selectedProjectId) {
				return null;
			}

			return await api.getProjectGitBranches(selectedProjectId);
		},
		staleTime: 30_000,
	});
	const activeModel = useMemo(
		() => availableModels.find((item) => item.model === selectedModel) ?? null,
		[availableModels, selectedModel],
	);
	const availableReasoningEfforts = useMemo(
		() => activeModel?.supportedReasoningEfforts.map((item) => item.reasoningEffort) ?? [],
		[activeModel],
	);
	const gitCurrentBranch = gitStatusQuery.data?.currentBranch ?? null;
	const permissionOptions = useMemo(
		() => ["plan", "default", "full"] as const,
		[],
	);
	const permissionLabel = permissionMode?.trim().length ? permissionMode : "default";
	const selectedModelName = activeModel?.displayName ?? selectedModel ?? "No model";
	const selectedReasoningLabel = selectedReasoningEffort ?? activeModel?.defaultReasoningEffort ?? "No reasoning";
	const selectedBranch = gitCurrentBranch ?? "No branch";
	const isGitRepository = gitStatusQuery.data?.isRepo ?? false;
	const availableBranches = useMemo(
		() => gitBranchesQuery.data?.branches ?? [],
		[gitBranchesQuery.data?.branches],
	);
	const branchOptions = useMemo(() => {
		if (!isGitRepository || !gitCurrentBranch) {
			return availableBranches;
		}

		if (availableBranches.includes(gitCurrentBranch)) {
			return availableBranches;
		}

		return [gitCurrentBranch, ...availableBranches];
	}, [availableBranches, gitCurrentBranch, isGitRepository]);

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

	const hasStreamingItems = Boolean(streamingTurn && streamingTurn.itemOrder.length > 0);

	useEffect(() => {
		let timer: ReturnType<typeof setTimeout> | null = null;

		if (!isKeyboardVisible) {
			timer = setTimeout(() => {
				selectorsScrollRef.current?.scrollToEnd({ animated: false });
			}, 0);
		}

		return () => {
			if (timer !== null) {
				clearTimeout(timer);
			}
		};
	}, [isKeyboardVisible, availableModels.length, availableReasoningEfforts.length, availableBranches.length, permissionMode, selectedBranch]);

	useEffect(() => {
		const onShow = () => {
			setIsKeyboardVisible(true);
			setActivePicker(null);
		};
		const onHide = () => {
			setIsKeyboardVisible(false);
		};
		const showSubscription = Keyboard.addListener("keyboardDidShow", onShow);
		const hideSubscription = Keyboard.addListener("keyboardDidHide", onHide);

		return () => {
			showSubscription.remove();
			hideSubscription.remove();
		};
	}, []);

	useEffect(() => {
		if (!activeModel || availableReasoningEfforts.length === 0) {
			return;
		}

		if (!selectedReasoningEffort || !availableReasoningEfforts.includes(selectedReasoningEffort)) {
			setSelectedReasoningEffort(activeModel.defaultReasoningEffort);
		}
	}, [activeModel, availableReasoningEfforts, selectedReasoningEffort, setSelectedReasoningEffort]);

	useEffect(() => {
		messageScrollRef.current?.scrollToEnd({ animated: true });
	}, [messages.length, streamingTurn]);

	useEffect(() => {
		let timer: ReturnType<typeof setTimeout> | null = null;

		if (isConfigLoaded && isLoaded && !serverHealthQuery.isPending) {
			if (serverHealthQuery.isError) {
				replace("/settings");
			} else if (!selectedProjectId) {
				replace("/workspaces");
			} else if (!selectedChatId && source !== "thread-list" && source !== "terminal") {
				timer = setTimeout(() => {
					if (!selectedChatId) {
						replace("/threads");
					}
				}, 180);
			} else {
				timer = null;
			}
		}

		return () => {
			if (timer !== null) {
				clearTimeout(timer);
			}
		};
	}, [
		isConfigLoaded,
		isLoaded,
		replace,
		selectedChatId,
		source,
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

	const openFilePicker = () => {
		Keyboard.dismiss();
		setIsFilePickerOpen(true);
	};

	const closeFilePicker = () => {
		setIsFilePickerOpen(false);
	};

	const handleAddAttachmentPaths = (paths: string[]) => {
		setInput((currentInput) => appendAttachmentPathsToMessage(currentInput, paths));
		setIsFilePickerOpen(false);
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
			onClosed();
		});
	};

	const openWorkspaceFromDrawer = (project: (typeof projects)[number]) => {
		selectProject(project);
		closeDrawer();
		replace("/threads");
	};

	const openSettingsFromDrawer = () => {
		closeDrawerThen(() => {
			replace("/settings");
		});
	};

	const createQuickChat = async () => {
		const chat = await createChat("New chat");
		if (chat) {
			setIsTerminalOpen(false);
			replace({
				params: {
					source: "terminal",
				},
				pathname: "/chat",
			});
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

	const isBranchPickerDisabled = !selectedProjectId || !isGitRepository || gitBranchesQuery.isLoading || isBranchCheckoutPending;

	const setPicker = useCallback(
		async (value: string) => {
			if (activePicker === null) {
				return;
			}

			switch (activePicker) {
				case "branch": {
					if (!selectedProjectId || !isGitRepository || value === selectedBranch || isBranchCheckoutPending) {
						setActivePicker(null);
						return;
					}

					setIsBranchCheckoutPending(true);
					try {
						await api.checkoutProjectGitBranch(selectedProjectId, value);
						await Promise.all([
							queryClient.invalidateQueries({
								queryKey: ["project-git-status", selectedProjectId],
							}),
							queryClient.invalidateQueries({
								queryKey: ["project-git-branches", selectedProjectId],
							}),
						]);
					} finally {
						setIsBranchCheckoutPending(false);
					}
					break;
				}
				case "model": {
					if (value !== selectedModel) {
						setSelectedModel(value);
					}
					break;
				}
				case "permission": {
					setPermissionMode(value);
					break;
				}
				case "reasoning": {
					setSelectedReasoningEffort(value);
					break;
				}
				default: {
					break;
				}
			}
			setActivePicker(null);
		},
		[
			activePicker,
			selectedBranch,
			selectedModel,
			selectedProjectId,
			isBranchCheckoutPending,
			isGitRepository,
			queryClient,
			api,
			setPermissionMode,
			setSelectedModel,
			setSelectedReasoningEffort,
			setIsBranchCheckoutPending,
		],
	);

	const activePickerOptions = useMemo((): JSX.Element[] => {
		const options: JSX.Element[] = [];

		switch (activePicker) {
			case "branch": {
				if (branchOptions.length === 0) {
					options.push(
						<Text key="no-branches" style={styles.selectModalEmpty}>
							No branches available.
						</Text>,
					);
					break;
				}

				options.push(
					...branchOptions.map((branch) => {
						const isCurrent = branch === gitCurrentBranch;
						return (
							<Pressable
								key={branch}
								onPress={() => {
									void setPicker(branch);
								}}
								style={({ pressed }) => [
									styles.selectModalItem,
									isCurrent ? styles.selectModalItemActive : null,
									pressed ? styles.selectModalItemPressed : null,
								]}
								disabled={isBranchPickerDisabled}
								testID={`chat-branch-option-${branch}`}
							>
								<Text numberOfLines={1} style={styles.selectModalItemLabel}>
									{branch}
								</Text>
							</Pressable>
						);
					}),
				);
				break;
			}
			case "model": {
				options.push(
					...availableModels.map((model) => {
						const isCurrent = model.model === selectedModel;
						return (
							<Pressable
								key={model.id}
								onPress={() => {
									void setPicker(model.model);
								}}
								style={({ pressed }) => [
									styles.selectModalItem,
									isCurrent ? styles.selectModalItemActive : null,
									pressed ? styles.selectModalItemPressed : null,
								]}
								testID={`chat-model-option-${model.id}`}
							>
								<Text numberOfLines={1} style={styles.selectModalItemLabel}>
									{model.displayName}
								</Text>
							</Pressable>
						);
					}),
				);
				break;
			}
			case "permission": {
				options.push(
					...permissionOptions.map((permission) => {
						const isCurrent = permission === permissionMode;
						return (
							<Pressable
								key={permission}
								onPress={() => {
									void setPicker(permission);
								}}
								style={({ pressed }) => [
									styles.selectModalItem,
									isCurrent ? styles.selectModalItemActive : null,
									pressed ? styles.selectModalItemPressed : null,
								]}
								testID={`chat-permission-option-${permission}`}
							>
								<Text numberOfLines={1} style={styles.selectModalItemLabel}>
									{permission}
								</Text>
							</Pressable>
						);
					}),
				);
				break;
			}
			case "reasoning": {
				options.push(
					...availableReasoningEfforts.map((effort) => {
						const isCurrent = effort === selectedReasoningEffort;
						return (
							<Pressable
								key={effort}
								onPress={() => {
									void setPicker(effort);
								}}
								style={({ pressed }) => [
									styles.selectModalItem,
									isCurrent ? styles.selectModalItemActive : null,
									pressed ? styles.selectModalItemPressed : null,
								]}
								testID={`chat-reasoning-option-${effort}`}
							>
								<Text numberOfLines={1} style={styles.selectModalItemLabel}>
									{effort}
								</Text>
							</Pressable>
						);
					}),
				);
				break;
			}
			default: {
				break;
			}
		}

		return options;
	}, [
		activePicker,
		availableModels,
		availableReasoningEfforts,
		permissionMode,
		branchOptions,
		gitCurrentBranch,
		selectedModel,
		selectedReasoningEffort,
		isBranchPickerDisabled,
		permissionOptions,
		setPicker,
	]);

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
					{messages.length === 0 && !hasStreamingItems ? (
						<Text style={styles.emptyState}>Start a conversation.</Text>
					) : null}

					{messages.map((message) => {
						const isUser = message.role === "user";
						return (
							<View
								key={message.id}
								style={[styles.messageRow, isUser ? styles.messageRowUser : styles.messageRowAssistant]}
							>
								{isUser ? (
									<View style={[styles.messageBubble, styles.userBubble]}>
										<MessageMarkdown
											content={message.content}
											linkColor={palette.accent}
											textColor={palette.text}
										/>
									</View>
								) : (
									<View style={styles.assistantMessageContent}>
										<MessageMarkdown
											content={message.content}
											linkColor={palette.accent}
											textColor={palette.text}
										/>
									</View>
								)}
							</View>
						);
					})}

					{hasStreamingItems && streamingTurn ? (
						<View style={[styles.messageRow, styles.messageRowAssistant]}>
							<View style={styles.assistantMessageContent}>
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
						<Text style={styles.typingLabel}>Thinking...</Text>
					) : null}
				</ScrollView>

				{lastError ? (
					<Text selectable style={styles.errorText}>
						{lastError}
					</Text>
				) : null}

				<View style={styles.composerRow}>
					<Pressable
						disabled={isSending || !selectedProjectId}
						onPress={openFilePicker}
						style={({ pressed }) => [
							styles.attachAction,
							pressed ? styles.attachActionPressed : null,
							isSending || !selectedProjectId ? styles.disabledButton : null,
						]}
						testID="chat-attach-button"
					>
						<MaterialIcons color={palette.text} name="add" size={22} />
					</Pressable>

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

				{!isKeyboardVisible ? (
					<ScrollView
						ref={selectorsScrollRef}
						contentContainerStyle={styles.selectorsScroller}
						horizontal
						showsHorizontalScrollIndicator={false}
						style={styles.selectorsRow}
					>
						<Pressable
							disabled={availableModels.length === 0}
							onPress={() => {
								setActivePicker("model");
							}}
							style={({ pressed }) => [
								styles.selectorButton,
								availableModels.length === 0 ? styles.selectorButtonDisabled : null,
								pressed && availableModels.length > 0 ? styles.selectorButtonPressed : null,
							]}
							testID="chat-model-picker-button"
						>
							<View style={styles.selectorButtonContent}>
								<Text numberOfLines={1} style={styles.selectorButtonLabel}>
									Model
								</Text>
								<Text numberOfLines={1} style={styles.selectorButtonValue}>
									{selectedModelName}
								</Text>
							</View>
							<MaterialIcons color={palette.muted} name="arrow-drop-down" size={18} />
						</Pressable>
						<Pressable
							disabled={availableReasoningEfforts.length === 0}
							onPress={() => {
								setActivePicker("reasoning");
							}}
							style={({ pressed }) => [
								styles.selectorButton,
								availableReasoningEfforts.length === 0 ? styles.selectorButtonDisabled : null,
								pressed && availableReasoningEfforts.length > 0 ? styles.selectorButtonPressed : null,
							]}
							testID="chat-reasoning-picker-button"
						>
							<View style={styles.selectorButtonContent}>
								<Text numberOfLines={1} style={styles.selectorButtonLabel}>
									Reasoning
								</Text>
								<Text numberOfLines={1} style={styles.selectorButtonValue}>
									{selectedReasoningLabel}
								</Text>
							</View>
							<MaterialIcons color={palette.muted} name="arrow-drop-down" size={18} />
						</Pressable>
						<Pressable
							onPress={() => {
								setActivePicker("permission");
							}}
							style={({ pressed }) => [
								styles.selectorButton,
								pressed ? styles.selectorButtonPressed : null,
							]}
						>
							<View style={styles.selectorButtonContent}>
								<Text numberOfLines={1} style={styles.selectorButtonLabel}>
									Permission
								</Text>
								<Text numberOfLines={1} style={styles.selectorButtonValue}>
									{permissionLabel}
								</Text>
							</View>
							<MaterialIcons color={palette.muted} name="arrow-drop-down" size={18} />
						</Pressable>
						<Pressable
							disabled={isBranchPickerDisabled}
							onPress={() => {
								setActivePicker("branch");
							}}
							style={({ pressed }) => [
								styles.selectorButton,
								isBranchPickerDisabled ? styles.selectorButtonDisabled : null,
								pressed && !isBranchPickerDisabled ? styles.selectorButtonPressed : null,
							]}
						>
							<View style={styles.selectorButtonContent}>
								<Text numberOfLines={1} style={styles.selectorButtonLabel}>
									Branch
								</Text>
								<Text numberOfLines={1} style={styles.selectorButtonValue}>
									{selectedBranch}
								</Text>
							</View>
							<MaterialIcons color={palette.muted} name="arrow-drop-down" size={18} />
						</Pressable>
					</ScrollView>
				) : null}
			</View>

			<Modal
				animationType="fade"
				onRequestClose={() => {
					setActivePicker(null);
				}}
				transparent
				visible={activePicker !== null}
			>
				<Pressable
					onPress={() => {
						setActivePicker(null);
					}}
					style={styles.selectModalBackdrop}
					testID="chat-select-modal-backdrop"
				>
					<Pressable
						onPress={() => {
							// no-op
						}}
						style={styles.selectModalPanel}
					>
							<Text style={styles.selectModalTitle}>{getSelectModalTitle(activePicker)}</Text>
							<ScrollView contentContainerStyle={styles.selectModalList} showsVerticalScrollIndicator={false}>
								{activePickerOptions}
							</ScrollView>
						</Pressable>
					</Pressable>
			</Modal>

			<DesktopFilePickerModal
				client={api}
				isVisible={isFilePickerOpen}
				onAddPaths={handleAddAttachmentPaths}
				onClose={closeFilePicker}
			/>

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
								style={styles.drawerListScroll}
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
	assistantMessageContent: {
		width: "100%",
	},
	attachAction: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.04)",
		borderColor: palette.border,
		borderRadius: 11,
		borderWidth: 1,
		height: 42,
		justifyContent: "center",
		width: 42,
	},
	attachActionPressed: {
		backgroundColor: "rgba(255,255,255,0.09)",
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
		paddingBottom: 6,
		paddingTop: 8,
	},
	selectorButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.05)",
		borderColor: palette.border,
		borderRadius: 11,
		borderWidth: 1,
		flexDirection: "row",
		flexShrink: 0,
		minWidth: 136,
		height: 44,
		maxHeight: 44,
		gap: 6,
		justifyContent: "space-between",
		overflow: "hidden",
		paddingHorizontal: 9,
		paddingVertical: 8,
	},
	selectorButtonContent: {
		flex: 1,
		minWidth: 0,
		justifyContent: "center",
	},
	selectorButtonDisabled: {
		opacity: 0.55,
	},
	selectorButtonLabel: {
		color: palette.muted,
		fontSize: 10.5,
		fontWeight: "600",
		letterSpacing: 0.15,
		lineHeight: 12.5,
		textTransform: "uppercase",
	},
	selectorButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	selectorButtonValue: {
		color: palette.text,
		fontSize: 12,
		lineHeight: 14,
		marginTop: 0,
	},
	selectorsRow: {
		flexDirection: "row",
		flexGrow: 0,
		flexShrink: 0,
	},
	selectorsScroller: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		marginBottom: 8,
		marginTop: 8,
	},
	selectModalBackdrop: {
		backgroundColor: "rgba(2,5,10,0.62)",
		flex: 1,
		justifyContent: "flex-end",
	},
	selectModalItem: {
		backgroundColor: "rgba(255,255,255,0.02)",
		borderColor: "rgba(255,255,255,0.15)",
		borderRadius: 10,
		borderWidth: 1,
		marginBottom: 8,
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	selectModalItemActive: {
		backgroundColor: "rgba(99,200,255,0.14)",
		borderColor: "rgba(99,200,255,0.74)",
	},
	selectModalItemLabel: {
		color: palette.text,
		fontSize: 14,
	},
	selectModalItemPressed: {
		opacity: 0.8,
	},
	selectModalList: {
		gap: 8,
		paddingTop: 8,
	},
	selectModalEmpty: {
		color: palette.muted,
		fontSize: 13,
		paddingBottom: 4,
	},
	selectModalPanel: {
		backgroundColor: palette.background,
		borderTopLeftRadius: 18,
		borderTopRightRadius: 18,
		maxHeight: 360,
		paddingHorizontal: 14,
		paddingBottom: 20,
		paddingTop: 10,
	},
	selectModalTitle: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "700",
		letterSpacing: 0.2,
		textAlign: "center",
		textTransform: "uppercase",
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
		width: "100%",
	},
	messageRowAssistant: {
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
