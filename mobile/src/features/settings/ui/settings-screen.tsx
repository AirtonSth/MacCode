import { useRouter } from "expo-router";
import { useCallback, useEffect, useMemo, useState } from "react";
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

import { useApiConfig } from "../../../shared/api/api-config-provider";
import { ApiConfigStore } from "../../../shared/api/api-config-store";
import { DiscoveryManager, type DiscoveredServer } from "../../../shared/api/discovery-manager";
import { createRemoteCodeClient } from "../../../shared/api/remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";

type StatusTone = "error" | "neutral" | "success";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

export const SettingsScreen = () => {
	const router = useRouter();
	const { config, update } = useApiConfig();
	const [baseUrl, setBaseUrl] = useState<string>(config.baseUrl);
	const [token, setToken] = useState<string>(config.token);
	const [statusTone, setStatusTone] = useState<StatusTone>("neutral");
	const [statusMessage, setStatusMessage] = useState<string>("");
	const [isScanning, setIsScanning] = useState<boolean>(false);
	const [isConnectingManual, setIsConnectingManual] = useState<boolean>(false);
	const [isContinuing, setIsContinuing] = useState<boolean>(false);
	const [isConnectingByServerId, setIsConnectingByServerId] = useState<Record<string, boolean>>({});
	const [discoveredServers, setDiscoveredServers] = useState<DiscoveredServer[]>([]);
	const [tokenByServerId, setTokenByServerId] = useState<Record<string, string>>({});

	const hasSavedServer = useMemo(
		() => config.baseUrl.trim().length > 0 && config.token.trim().length > 0,
		[config.baseUrl, config.token],
	);

	const setStatus = (message: string, tone: StatusTone = "neutral") => {
		setStatusMessage(message);
		setStatusTone(tone);
	};

	const goNext = () => {
		router.push("/workspaces");
	};

	const scanLan = useCallback(async () => {
		setIsScanning(true);
		setStatusMessage("");
		try {
			const found = await DiscoveryManager.scan();
			setDiscoveredServers(found);
			setStatus(found.length === 0 ? "No server found on local network." : `Found ${String(found.length)} server(s).`);
		} catch (error: unknown) {
			setStatus(error instanceof Error ? error.message : "Failed to scan local network.", "error");
		} finally {
			setIsScanning(false);
		}
	}, []);

	const hydrateRecentServers = useCallback(async () => {
		const recent = await DiscoveryManager.readRecent();
		setDiscoveredServers(recent);

		const pairs = await Promise.all(
			recent.map(async (server) => {
				const storedToken = await ApiConfigStore.readTokenForServer(server.serverId);
				return [server.serverId, storedToken ?? ""] as const;
			}),
		);

		setTokenByServerId((current) => {
			const next = { ...current };
			for (const [serverId, storedToken] of pairs) {
				next[serverId] ||= storedToken;
			}
			return next;
		});
	}, []);

	useEffect(() => {
		void hydrateRecentServers();
		void scanLan();
	}, [hydrateRecentServers, scanLan]);

	const connectAndPersist = async (input: { baseUrl: string; token: string; serverId?: string }) => {
		const normalizedBaseUrl = input.baseUrl.trim();
		const normalizedToken = input.token.trim();

		if (!normalizedBaseUrl || !normalizedToken) {
			setStatus("Server URL and token are required.", "error");
			return false;
		}

		try {
			const verifyClient = createRemoteCodeClient({
				baseUrl: normalizedBaseUrl,
				token: normalizedToken,
			});
			await verifyClient.verifyToken(normalizedToken, normalizedBaseUrl);

			if (input.serverId) {
				await ApiConfigStore.saveServerConnection({
					baseUrl: normalizedBaseUrl,
					serverId: input.serverId,
					token: normalizedToken,
				});
			}

			await update({
				baseUrl: normalizedBaseUrl,
				token: normalizedToken,
			});
			setBaseUrl(normalizedBaseUrl);
			setToken(normalizedToken);
			setStatus("Server connected.", "success");
			return true;
		} catch (error: unknown) {
			setStatus(error instanceof Error ? error.message : "Unable to connect to server.", "error");
			return false;
		}
	};

	const continueWithSaved = async () => {
		if (!hasSavedServer) {
			setStatus("No saved server connection found.", "error");
			return;
		}

		setIsContinuing(true);
		setStatusMessage("");
		const connected = await connectAndPersist({
			baseUrl: config.baseUrl,
			token: config.token,
		});
		setIsContinuing(false);
		if (connected) {
			goNext();
		}
	};

	const connectManual = async () => {
		setIsConnectingManual(true);
		setStatusMessage("");
		const connected = await connectAndPersist({
			baseUrl,
			token,
		});
		setIsConnectingManual(false);
		if (connected) {
			goNext();
		}
	};

	const connectDiscoveredServer = async (server: DiscoveredServer) => {
		const selectedToken = (tokenByServerId[server.serverId] ?? token).trim();
		setIsConnectingByServerId((current) => ({ ...current, [server.serverId]: true }));
		setStatusMessage("");

		const connected = await connectAndPersist({
			baseUrl: server.baseUrl,
			serverId: server.serverId,
			token: selectedToken,
		});

		setIsConnectingByServerId((current) => ({ ...current, [server.serverId]: false }));
		if (connected) {
			goNext();
		}
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
			testID="screen-settings"
		>
			<IosStackHeader subtitle="Select server connection" title="Server" />

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				keyboardShouldPersistTaps="handled"
				showsVerticalScrollIndicator={false}
			>
				<View style={styles.section}>
					<View style={styles.sectionHeader}>
						<Text style={styles.sectionTitle}>Saved Connection</Text>
						<Pressable
							disabled={!hasSavedServer || isContinuing}
							onPress={() => {
								void continueWithSaved();
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								pressed ? styles.secondaryButtonPressed : null,
								!hasSavedServer || isContinuing ? styles.disabledButton : null,
							]}
							testID="server-continue-button"
						>
							<Text style={styles.secondaryLabel}>{isContinuing ? "Checking..." : "Continue"}</Text>
						</Pressable>
					</View>
					<Text selectable style={styles.supportText}>
						{hasSavedServer ? config.baseUrl : "No active server yet."}
					</Text>
				</View>

				<View style={styles.section}>
					<View style={styles.sectionHeader}>
						<Text style={styles.sectionTitle}>LAN Discovery</Text>
						<Pressable
							onPress={() => {
								void scanLan();
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
							testID="server-scan-button"
						>
							<Text style={styles.secondaryLabel}>{isScanning ? "Scanning..." : "Scan"}</Text>
						</Pressable>
					</View>

					{isScanning ? <ActivityIndicator color={palette.accent} /> : null}

					{discoveredServers.length === 0 ? (
						<Text style={styles.supportText}>No discovered server.</Text>
					) : (
						discoveredServers.map((server, index) => {
							const isConnecting = Boolean(isConnectingByServerId[server.serverId]);
							return (
								<View key={server.serverId} style={styles.listRow} testID={`server-item-${String(index)}`}>
									<Text numberOfLines={1} style={styles.rowTitle}>
										{server.hostname}:{String(server.port)}
									</Text>
									<Text selectable style={styles.rowMeta}>
										{server.baseUrl}
									</Text>
									<TextInput
										autoCapitalize="none"
										onChangeText={(value) => {
											setTokenByServerId((current) => ({
												...current,
												[server.serverId]: value,
											}));
										}}
										placeholder="Server token"
										placeholderTextColor={palette.muted}
										style={styles.input}
										testID={`server-token-${String(index)}`}
										value={tokenByServerId[server.serverId] ?? ""}
									/>
									<Pressable
										onPress={() => {
											void connectDiscoveredServer(server);
										}}
										style={({ pressed }) => [
											styles.primaryButton,
											pressed ? styles.primaryButtonPressed : null,
										]}
										testID={`server-connect-${String(index)}`}
									>
										<Text style={styles.primaryLabel}>{isConnecting ? "Connecting..." : "Connect"}</Text>
									</Pressable>
								</View>
							);
						})
					)}
				</View>

				<View style={styles.section}>
					<View style={styles.sectionHeader}>
						<Text style={styles.sectionTitle}>Manual Connection</Text>
					</View>

					<View style={styles.formBody}>
						<TextInput
							autoCapitalize="none"
							onChangeText={setBaseUrl}
							placeholder="http://127.0.0.1:8835"
							placeholderTextColor={palette.muted}
							style={styles.input}
							testID="server-manual-base-url"
							value={baseUrl}
						/>
						<TextInput
							autoCapitalize="none"
							onChangeText={setToken}
							placeholder="Token"
							placeholderTextColor={palette.muted}
							style={styles.input}
							testID="server-manual-token"
							value={token}
						/>
						<Pressable
							disabled={isConnectingManual}
							onPress={() => {
								void connectManual();
							}}
							style={({ pressed }) => [
								styles.primaryButton,
								pressed ? styles.primaryButtonPressed : null,
								isConnectingManual ? styles.disabledButton : null,
							]}
							testID="server-manual-connect"
						>
							<Text style={styles.primaryLabel}>{isConnectingManual ? "Connecting..." : "Connect"}</Text>
						</Pressable>
					</View>
				</View>

				{statusMessage.length > 0 ? (
					<View
						style={[
							styles.statusBox,
							statusTone === "error" ? styles.statusError : null,
							statusTone === "success" ? styles.statusSuccess : null,
						]}
					>
						<Text selectable style={styles.statusText}>
							{statusMessage}
						</Text>
					</View>
				) : null}
			</ScrollView>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	content: {
		gap: 12,
		paddingBottom: 36,
		paddingHorizontal: 16,
		paddingTop: 14,
	},
	disabledButton: {
		opacity: 0.45,
	},
	formBody: {
		gap: 10,
	},
	input: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		color: palette.text,
		fontSize: 15,
		minHeight: 42,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	listRow: {
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		gap: 8,
		padding: 12,
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 11,
		height: 38,
		justifyContent: "center",
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
	secondaryButton: {
		alignItems: "center",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		height: 34,
		justifyContent: "center",
		paddingHorizontal: 12,
	},
	secondaryButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	secondaryLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	section: {
		backgroundColor: "#12161E",
		borderColor: palette.border,
		borderRadius: 14,
		borderWidth: 1,
		gap: 10,
		padding: 12,
	},
	sectionHeader: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
	},
	sectionTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "700",
	},
	statusBox: {
		backgroundColor: "rgba(255,255,255,0.06)",
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		padding: 12,
	},
	statusError: {
		backgroundColor: "rgba(255,107,133,0.16)",
		borderColor: "rgba(255,107,133,0.38)",
	},
	statusSuccess: {
		backgroundColor: "rgba(99,200,255,0.14)",
		borderColor: "rgba(99,200,255,0.36)",
	},
	statusText: {
		color: palette.text,
		fontSize: 13,
		lineHeight: 19,
	},
	supportText: {
		color: palette.muted,
		fontSize: 13,
		lineHeight: 18,
	},
});
