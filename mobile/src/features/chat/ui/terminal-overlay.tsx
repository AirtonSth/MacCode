import { MaterialIcons } from "@expo/vector-icons";
import { memo, type RefObject } from "react";
import {
	KeyboardAvoidingView,
	Modal,
	Platform,
	Pressable,
	ScrollView,
	Text,
	TextInput,
	View,
} from "react-native";

import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { RemoteCodeClient } from "../../../shared/api/remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { DesktopFilePickerModal } from "./desktop-file-picker-modal";
import { chatScreenPalette, chatScreenStyles } from "./chat-screen-styles";

export interface TerminalOverlayProps {
	api: RemoteCodeClient;
	chatTitle: string | undefined;
	isTerminalFilePickerVisible: boolean;
	isTerminalLoading: boolean;
	isTerminalOpen: boolean;
	isTerminalRunning: boolean;
	onAddPaths: (paths: string[]) => void;
	onChangeInput: (text: string) => void;
	onClose: () => void;
	onCloseFilePicker: () => void;
	onOpenFilePicker: () => void;
	onRun: () => void;
	selectedChatId: string | null;
	terminalError: string;
	terminalInput: string;
	terminalOutput: string;
	terminalScrollRef: RefObject<ScrollView | null>;
}

// eslint-disable-next-line total-functions/no-unsafe-readonly-mutable-assignment
export const TerminalOverlay = memo(function TerminalOverlay(props: TerminalOverlayProps) {
	const insets = useSafeAreaInsets();
	return (
		<Modal
			animationType="slide"
			onRequestClose={props.onClose}
			presentationStyle="fullScreen"
			visible={props.isTerminalOpen}
		>
			<KeyboardAvoidingView
				behavior={Platform.OS === "ios" ? "padding" : "height"}
				style={chatScreenStyles.terminalRoot}
				testID="terminal-modal"
			>
				<IosStackHeader
					onBack={props.onClose}
					subtitle={props.chatTitle ?? "No thread selected"}
					title="Terminal"
				/>
				<View
					style={[
						chatScreenStyles.terminalBody,
						{
							paddingLeft: Math.max(12, insets.left),
							paddingRight: Math.max(12, insets.right),
							paddingBottom: Math.max(16, insets.bottom),
						},
					]}
				>
					<ScrollView
						contentContainerStyle={chatScreenStyles.terminalOutputContent}
						contentInsetAdjustmentBehavior="automatic"
						ref={props.terminalScrollRef}
						showsVerticalScrollIndicator={false}
						style={chatScreenStyles.terminalOutput}
					>
						{props.isTerminalLoading ? <Text style={chatScreenStyles.terminalMeta}>Loading history...</Text> : null}
						<Text selectable style={chatScreenStyles.terminalText}>
							{props.terminalOutput || "No terminal output yet."}
						</Text>
					</ScrollView>
					{props.terminalError.length > 0 ? (
						<Text selectable style={chatScreenStyles.errorText}>
							{props.terminalError}
						</Text>
					) : null}
					<View style={chatScreenStyles.terminalComposer}>
						<Pressable
							disabled={props.isTerminalRunning || !props.selectedChatId}
							onPress={props.onOpenFilePicker}
							style={({ pressed }) => [
								chatScreenStyles.attachAction,
								pressed ? chatScreenStyles.attachActionPressed : null,
								props.isTerminalRunning || !props.selectedChatId ? chatScreenStyles.disabledButton : null,
							]}
							testID="terminal-attach-button"
						>
							<MaterialIcons color={chatScreenPalette.text} name="add" size={22} />
						</Pressable>
						<TextInput
							autoCapitalize="none"
							onChangeText={props.onChangeInput}
							onSubmitEditing={props.onRun}
							placeholder="Run command"
							placeholderTextColor={chatScreenPalette.muted}
							style={chatScreenStyles.composerInput}
							testID="terminal-command-input"
							value={props.terminalInput}
						/>
						<Pressable
							disabled={props.isTerminalRunning || !props.selectedChatId}
							onPress={props.onRun}
							style={({ pressed }) => [
								chatScreenStyles.primaryAction,
								pressed ? chatScreenStyles.primaryActionPressed : null,
								props.isTerminalRunning || !props.selectedChatId ? chatScreenStyles.disabledButton : null,
							]}
							testID="terminal-run-button"
						>
							<Text style={chatScreenStyles.primaryActionLabel}>{props.isTerminalRunning ? "..." : "Run"}</Text>
						</Pressable>
					</View>
				</View>
				<DesktopFilePickerModal
					client={props.api}
					isVisible={props.isTerminalFilePickerVisible}
					onAddPaths={props.onAddPaths}
					onClose={props.onCloseFilePicker}
				/>
			</KeyboardAvoidingView>
		</Modal>
	);
});
