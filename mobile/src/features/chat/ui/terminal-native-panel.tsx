import { useMemo, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";

import type { TerminalViewport } from "@remotecode/contracts";

import type { TerminalPtyChatState } from "../model/use-terminal-pty-session";
import { chatScreenPalette } from "./chat-screen-styles";
import TerminalXtermDom from "./terminal-xterm-dom";

interface TerminalNativePanelProps {
	chatId: string | null;
	onInput: (data: string) => void;
	onInterrupt: () => void;
	onOpenFilePicker: (() => void) | null;
	onResize: (viewport: TerminalViewport) => void;
	onRestart: () => void;
	state: TerminalPtyChatState | null;
}

const terminalHelperKeys = [
	{ key: "escape", label: "Esc", value: "\u001B" },
	{ key: "tab", label: "Tab", value: "\t" },
	{ key: "left", label: "Left", value: "\u001B[D" },
	{ key: "right", label: "Right", value: "\u001B[C" },
	{ key: "up", label: "Up", value: "\u001B[A" },
	{ key: "down", label: "Down", value: "\u001B[B" },
	{ key: "ctrl-c", label: "Ctrl+C", value: "\u0003" },
	{ key: "ctrl-d", label: "Ctrl+D", value: "\u0004" },
] as const;

const panelStyles = StyleSheet.create({
	actionButton: {
		alignItems: "center",
		borderColor: chatScreenPalette.border,
		borderRadius: 10,
		borderWidth: 1,
		minHeight: 34,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	actionButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	actionButtonPrimary: {
		backgroundColor: "rgba(99,200,255,0.14)",
		borderColor: "rgba(99,200,255,0.44)",
	},
	actionLabel: {
		color: chatScreenPalette.text,
		fontSize: 12,
		fontWeight: "700",
	},
	body: {
		flex: 1,
		gap: 10,
		minHeight: 0,
	},
	helperButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.04)",
		borderColor: chatScreenPalette.border,
		borderRadius: 10,
		borderWidth: 1,
		minWidth: 58,
		paddingHorizontal: 10,
		paddingVertical: 8,
	},
	helperButtonActive: {
		backgroundColor: "rgba(99,200,255,0.18)",
		borderColor: "rgba(99,200,255,0.48)",
	},
	helperRow: {
		flexDirection: "row",
		flexWrap: "wrap",
		gap: 8,
	},
	metaRow: {
		flexDirection: "row",
		flexWrap: "wrap",
		gap: 10,
		justifyContent: "space-between",
	},
	metaText: {
		color: chatScreenPalette.muted,
		fontSize: 12,
	},
	placeholder: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.02)",
		borderColor: chatScreenPalette.border,
		borderRadius: 16,
		borderWidth: 1,
		flex: 1,
		justifyContent: "center",
		minHeight: 220,
		paddingHorizontal: 24,
	},
	placeholderText: {
		color: chatScreenPalette.muted,
		fontSize: 13,
		textAlign: "center",
	},
	terminalFrame: {
		flex: 1,
		minHeight: 220,
	},
	topActions: {
		flexDirection: "row",
		flexWrap: "wrap",
		gap: 8,
	},
});

export function TerminalNativePanel({
	chatId,
	onInput,
	onInterrupt,
	onOpenFilePicker,
	onResize,
	onRestart,
	state,
}: TerminalNativePanelProps) {
	const [isCtrlModeActive, setIsCtrlModeActive] = useState(false);
	const sessionStatus = state?.status ?? (chatId ? "joining" : "idle");
	const sessionMeta = useMemo(() => {
		if (!state) {
			return chatId ? "Connecting..." : "Select a thread to start a terminal session.";
		}

		if (state.cwd) {
			return state.cwd;
		}

		return state.status === "exited" ? "Session exited" : "Connecting...";
	}, [chatId, state]);

	const handleHelperInput = (value: string) => {
		setIsCtrlModeActive(false);
		onInput(value);
	};

	return (
		<View style={panelStyles.body}>
			<View style={panelStyles.metaRow}>
				<Text numberOfLines={1} style={panelStyles.metaText} testID="terminal-session-cwd">
					{sessionMeta}
				</Text>
				<Text style={panelStyles.metaText} testID="terminal-session-status">
					{sessionStatus}
				</Text>
			</View>

			<View style={panelStyles.topActions}>
				{onOpenFilePicker ? (
					<Pressable
						disabled={!chatId}
						onPress={() => {
							onOpenFilePicker();
						}}
						style={({ pressed }) => [
							panelStyles.actionButton,
							panelStyles.actionButtonPrimary,
							pressed ? panelStyles.actionButtonPressed : null,
							!chatId ? { opacity: 0.45 } : null,
						]}
						testID="terminal-add-paths-button"
					>
						<Text style={panelStyles.actionLabel}>Add Paths</Text>
					</Pressable>
				) : null}

				<Pressable
					disabled={!chatId}
					onPress={() => {
						setIsCtrlModeActive(false);
						onInterrupt();
					}}
					style={({ pressed }) => [
						panelStyles.actionButton,
						pressed ? panelStyles.actionButtonPressed : null,
						!chatId ? { opacity: 0.45 } : null,
					]}
					testID="terminal-interrupt-button"
				>
					<Text style={panelStyles.actionLabel}>Interrupt</Text>
				</Pressable>

				<Pressable
					disabled={!chatId}
					onPress={() => {
						setIsCtrlModeActive(false);
						onRestart();
					}}
					style={({ pressed }) => [
						panelStyles.actionButton,
						pressed ? panelStyles.actionButtonPressed : null,
						!chatId ? { opacity: 0.45 } : null,
					]}
					testID="terminal-restart-button"
				>
					<Text style={panelStyles.actionLabel}>Restart</Text>
				</Pressable>
			</View>

			<View style={panelStyles.helperRow}>
				<Pressable
					disabled={!chatId}
					onPress={() => {
						setIsCtrlModeActive((current) => !current);
					}}
					style={({ pressed }) => [
						panelStyles.helperButton,
						isCtrlModeActive ? panelStyles.helperButtonActive : null,
						pressed ? panelStyles.actionButtonPressed : null,
						!chatId ? { opacity: 0.45 } : null,
					]}
					testID="terminal-helper-ctrl"
				>
					<Text style={panelStyles.actionLabel}>Ctrl</Text>
				</Pressable>

				{terminalHelperKeys.map((item) => (
					<Pressable
						disabled={!chatId}
						key={item.key}
						onPress={() => {
							handleHelperInput(item.value);
						}}
						style={({ pressed }) => [
							panelStyles.helperButton,
							pressed ? panelStyles.actionButtonPressed : null,
							!chatId ? { opacity: 0.45 } : null,
						]}
						testID={`terminal-helper-${item.key}`}
					>
						<Text style={panelStyles.actionLabel}>{item.label}</Text>
					</Pressable>
				))}
			</View>

			{chatId ? (
				<View style={panelStyles.terminalFrame} testID="terminal-surface">
					<TerminalXtermDom
						chatId={chatId}
						isCtrlModeActive={isCtrlModeActive}
						dom={{
							scrollEnabled: false,
							style: { flex: 1 },
							useExpoDOMWebView: true,
						}}
						lastOutputData={state?.lastOutput?.data ?? ""}
						lastOutputId={state?.lastOutput?.id ?? null}
						onCtrlModeActiveChange={async (active) => {
							setIsCtrlModeActive(active);
						}}
						onInput={async (data) => {
							onInput(data);
						}}
						onResize={async (viewport) => {
							onResize(viewport);
						}}
						sessionId={state?.sessionId ?? null}
						snapshot={state?.snapshot ?? ""}
					/>
				</View>
			) : (
				<View style={panelStyles.placeholder}>
					<Text style={panelStyles.placeholderText}>
						Select a thread to start a terminal session.
					</Text>
				</View>
			)}
		</View>
	);
}
