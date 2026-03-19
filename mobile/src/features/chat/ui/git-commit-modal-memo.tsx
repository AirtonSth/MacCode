import { MaterialIcons } from "@expo/vector-icons";
import { memo } from "react";
import {
	Modal,
	Pressable,
	Switch,
	Text,
	TextInput,
	View,
} from "react-native";

import { chatScreenPalette, chatScreenStyles } from "./chat-screen-styles";

type GitCommitAction = "commit" | "push";

export interface GitCommitModalProps {
	gitChangedFiles: number;
	gitCommitError: string;
	gitCommitIncludeUnstaged: boolean;
	gitCommitMessage: string;
	gitCurrentBranch: string | null;
	gitStatusData: { added: number; removed: number } | null | undefined;
	isGitCommitPending: boolean;
	isVisible: boolean;
	onChangeIncludeUnstaged: (value: boolean) => void;
	onChangeMessage: (text: string) => void;
	onClose: () => void;
	onCommit: (action: GitCommitAction) => void;
}

// eslint-disable-next-line total-functions/no-unsafe-readonly-mutable-assignment
export const GitCommitModalMemo = memo(function GitCommitModalMemo(props: GitCommitModalProps) {
	return (
		<Modal
			animationType="fade"
			onRequestClose={() => {
				if (props.isGitCommitPending) {
					return;
				}
				props.onClose();
			}}
			transparent
			visible={props.isVisible}
		>
			<Pressable
				onPress={() => {
					if (props.isGitCommitPending) {
						return;
					}
					props.onClose();
				}}
				style={chatScreenStyles.gitCommitModalBackdrop}
				testID="chat-git-commit-modal-backdrop"
			>
				<Pressable
					onPress={() => {
						// no-op
					}}
					style={chatScreenStyles.gitCommitModalPanel}
					testID="chat-git-commit-modal"
				>
					<View style={chatScreenStyles.gitCommitModalHeader}>
						<Text style={chatScreenStyles.gitCommitModalTitle}>
							{props.isGitCommitPending ? "Committing changes..." : "Commit your changes"}
						</Text>
						<Pressable
							accessibilityLabel="Close commit modal"
							disabled={props.isGitCommitPending}
							onPress={props.onClose}
							style={({ pressed }) => [
								chatScreenStyles.gitCommitCloseButton,
								props.isGitCommitPending ? chatScreenStyles.disabledButton : null,
								pressed && !props.isGitCommitPending ? chatScreenStyles.gitCommitCloseButtonPressed : null,
							]}
						>
							<MaterialIcons color={chatScreenPalette.muted} name="close" size={18} />
						</Pressable>
					</View>
					<View style={chatScreenStyles.gitCommitInfoRow}>
						<Text style={chatScreenStyles.gitCommitInfoLabel}>Branch</Text>
						<Text numberOfLines={1} style={chatScreenStyles.gitCommitInfoValue}>
							{props.gitCurrentBranch ?? "Detached"}
						</Text>
					</View>
					<View style={chatScreenStyles.gitCommitInfoRow}>
						<Text style={chatScreenStyles.gitCommitInfoLabel}>Changes</Text>
						<Text style={chatScreenStyles.gitCommitInfoValue}>
							{String(props.gitChangedFiles)} ·{" "}
							<Text style={chatScreenStyles.gitCommitAdded}>+{String(props.gitStatusData?.added ?? 0)}</Text> /{" "}
							<Text style={chatScreenStyles.gitCommitRemoved}>-{String(props.gitStatusData?.removed ?? 0)}</Text>
						</Text>
					</View>
					<View style={chatScreenStyles.gitCommitSwitchRow}>
						<Text style={chatScreenStyles.gitCommitSwitchLabel}>Include unstaged</Text>
						<Switch
							disabled={props.isGitCommitPending}
							onValueChange={props.onChangeIncludeUnstaged}
							testID="chat-git-commit-include-unstaged"
							thumbColor="#ffffff"
							trackColor={{ false: "rgba(148,163,184,0.38)", true: "rgba(99,200,255,0.85)" }}
							value={props.gitCommitIncludeUnstaged}
						/>
					</View>
					<TextInput
						editable={!props.isGitCommitPending}
						onChangeText={props.onChangeMessage}
						placeholder="Leave blank to autogenerate commit message"
						placeholderTextColor={chatScreenPalette.muted}
						style={chatScreenStyles.gitCommitMessageInput}
						testID="chat-git-commit-message-input"
						value={props.gitCommitMessage}
					/>
					<View style={chatScreenStyles.gitCommitActionRow}>
						<Pressable
							disabled={props.isGitCommitPending || props.gitChangedFiles <= 0}
							onPress={() => {
								props.onCommit("commit");
							}}
							style={({ pressed }) => [
								chatScreenStyles.gitCommitChoiceButton,
								pressed ? chatScreenStyles.gitCommitChoiceButtonPressed : null,
								props.isGitCommitPending || props.gitChangedFiles <= 0 ? chatScreenStyles.disabledButton : null,
							]}
							testID="chat-git-commit-action-commit"
						>
							<Text style={chatScreenStyles.gitCommitChoiceLabel}>Commit</Text>
						</Pressable>
						<Pressable
							disabled={props.isGitCommitPending || props.gitChangedFiles <= 0}
							onPress={() => {
								props.onCommit("push");
							}}
							style={({ pressed }) => [
								chatScreenStyles.gitCommitChoiceButton,
								chatScreenStyles.gitCommitFooterPrimaryButton,
								pressed ? chatScreenStyles.gitCommitFooterPrimaryButtonPressed : null,
								props.isGitCommitPending || props.gitChangedFiles <= 0 ? chatScreenStyles.disabledButton : null,
							]}
							testID="chat-git-commit-action-push"
						>
							<Text style={chatScreenStyles.gitCommitChoiceLabel}>Commit + Push</Text>
						</Pressable>
					</View>
					{props.gitCommitError ? <Text style={chatScreenStyles.gitCommitError}>{props.gitCommitError}</Text> : null}
				</Pressable>
			</Pressable>
		</Modal>
	);
});
