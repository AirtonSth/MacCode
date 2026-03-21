import { memo } from "react";
import {
	KeyboardAvoidingView,
	Modal,
	Platform,
	View,
} from "react-native";

import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { TerminalViewport } from "@remotecode/contracts";

import type { RemoteCodeClient } from "../../../shared/api/remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import type { TerminalPtyChatState } from "../model/use-terminal-pty-session";
import { DesktopFilePickerModal } from "./desktop-file-picker-modal";
import { chatScreenStyles } from "./chat-screen-styles";
import { TerminalNativePanel } from "./terminal-native-panel";

export interface TerminalOverlayProps {
	api: RemoteCodeClient;
	chatId: string | null;
	chatTitle: string | undefined;
	isTerminalFilePickerVisible: boolean;
	isTerminalOpen: boolean;
	onAddPaths: (paths: string[]) => void;
	onClose: () => void;
	onCloseFilePicker: () => void;
	onInput: (data: string) => void;
	onInterrupt: () => void;
	onOpenFilePicker: () => void;
	onResize: (viewport: TerminalViewport) => void;
	onRestart: () => void;
	state: TerminalPtyChatState | null;
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
					<TerminalNativePanel
						chatId={props.chatId}
						onInput={props.onInput}
						onInterrupt={props.onInterrupt}
						onOpenFilePicker={props.onOpenFilePicker}
						onResize={props.onResize}
						onRestart={props.onRestart}
						state={props.state}
					/>
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
