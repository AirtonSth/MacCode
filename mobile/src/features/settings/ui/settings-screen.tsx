import { LinearGradient } from "expo-linear-gradient";
import { useRouter } from "expo-router";
import { useEffect, useMemo, useState } from "react";
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

type StatusTone = "neutral" | "success" | "error";

const palette = {
	accent: "#6DE3C2",
	accentPressed: "#53C9AB",
	background: "#050A15",
	card: "rgba(11, 24, 45, 0.86)",
	cardSoft: "rgba(10, 18, 34, 0.7)",
	line: "rgba(255, 255, 255, 0.12)",
	muted: "#93A6C7",
	text: "#F3F7FF",
};

export const SettingsScreen = () => {
	const { config, update } = useApiConfig();
	const router = useRouter();

	const [baseUrl, setBaseUrl] = useState<string>(config.baseUrl);
	const [token, setToken] = useState<string>(config.token);
	const [discoveredServers, setDiscoveredServers] = useState<DiscoveredServer[]>([]);
	const [tokenByServerId, setTokenByServerId] = useState<Record<string, string>>({});
	const [isScanning, setIsScanning] = useState<boolean>(false);
	const [isSaving, setIsSaving] = useState<boolean>(false);
	const [isConnectingByServerId, setIsConnectingByServerId] = useState<Record<string, boolean>>({});
	const [statusMessage, setStatusMessage] = useState<string | null>(null);
	const [statusTone, setStatusTone] = useState<StatusTone>("neutral");

	const hasCurrentConnection = useMemo(
		() => config.baseUrl.trim().length > 0 && config.token.trim().length > 0,
		[config.baseUrl, config.token],
	);

	const setStatus = (message: string | null, tone: StatusTone = "neutral") => {
		setStatusMessage(message);
		setStatusTone(tone);
	};

	const loadRecent = async () => {
		const recent = await DiscoveryManager.readRecent();
		setDiscoveredServers(recent);

		const tokenPairs = await Promise.all(
			recent.map(async (server) => {
				const storedToken = await ApiConfigStore.readTokenForServer(server.serverId);
				return [server.serverId, storedToken ?? ""] as const;
			}),
		);

		setTokenByServerId((current) => {
			const next = { ...current };
			for (const [serverId, savedToken] of tokenPairs) {
				next[serverId] ||= savedToken;
			}
			return next;
		});
	};

	useEffect(() => {
		void loadRecent();
	}, []);

	const scanServers = async () => {
		setIsScanning(true);
		setStatus(null);

		try {
			const found = await DiscoveryManager.scan();
			setDiscoveredServers(found);

			const tokenPairs = await Promise.all(
				found.map(async (server) => {
					const storedToken = await ApiConfigStore.readTokenForServer(server.serverId);
					return [server.serverId, storedToken ?? ""] as const;
				}),
			);

			setTokenByServerId((current) => {
				const next = { ...current };
				for (const [serverId, savedToken] of tokenPairs) {
					next[serverId] ||= savedToken;
				}
				return next;
			});
		} catch (error) {
			setStatus(error instanceof Error ? error.message : "Unable to scan the local network.", "error");
		} finally {
			setIsScanning(false);
		}
	};

	const connectManual = async () => {
		const trimmedBaseUrl = baseUrl.trim();
		const trimmedToken = token.trim();

		if (!trimmedBaseUrl || !trimmedToken) {
			setStatus("Enter both server URL and token.", "error");
			return;
		}

		setIsSaving(true);
		setStatus(null);

		try {
			const verifyClient = createRemoteCodeClient({
				baseUrl: trimmedBaseUrl,
				token: trimmedToken,
			});
			await verifyClient.verifyToken(trimmedToken, trimmedBaseUrl);

			await update({
				baseUrl: trimmedBaseUrl,
				token: trimmedToken,
			});

			setStatus(`Connected to ${trimmedBaseUrl}`, "success");
			router.push("/workspaces");
		} catch (error) {
			setStatus(error instanceof Error ? error.message : "Unable to connect using manual settings.", "error");
		} finally {
			setIsSaving(false);
		}
	};

	const connectServer = async (server: DiscoveredServer) => {
		const selectedToken = (tokenByServerId[server.serverId] ?? "").trim() || token.trim();
		if (!selectedToken) {
			setStatus("Token is required to connect to this server.", "error");
			return;
		}

		setIsConnectingByServerId((current) => ({
			...current,
			[server.serverId]: true,
		}));
		setStatus(null);

		try {
			const verifyClient = createRemoteCodeClient({
				baseUrl: server.baseUrl,
				token: selectedToken,
			});
			await verifyClient.verifyToken(selectedToken, server.baseUrl);

			await ApiConfigStore.saveServerConnection({
				serverId: server.serverId,
				baseUrl: server.baseUrl,
				token: selectedToken,
			});
			await update({
				baseUrl: server.baseUrl,
				token: selectedToken,
			});

			setBaseUrl(server.baseUrl);
			setToken(selectedToken);
			setStatus(`Connected to ${server.hostname}:${String(server.port)}`, "success");
			router.push("/workspaces");
		} catch (error) {
			setStatus(error instanceof Error ? error.message : "Unable to connect to selected server.", "error");
		} finally {
			setIsConnectingByServerId((current) => ({
				...current,
				[server.serverId]: false,
			}));
		}
	};

	const continueWithCurrent = () => {
		if (!hasCurrentConnection) {
			setStatus("No saved connection found. Connect manually or choose a discovered server.", "error");
			return;
		}

		setStatus(null);
		router.push("/workspaces");
	};

	return (
		<KeyboardAvoidingView
			behavior={Platform.OS === "ios" ? "padding" : undefined}
			style={styles.root}
		>
			<LinearGradient
				colors={["#1B2E57", "#0D1C36", palette.background]}
				end={{ x: 0.9, y: 1 }}
				start={{ x: 0.1, y: 0 }}
				style={StyleSheet.absoluteFill}
			/>

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				showsVerticalScrollIndicator={false}
			>
				<View style={styles.headerRow}>
					<Text style={styles.stepLabel}>STEP 1 OF 4</Text>
				</View>

				<View style={styles.progressRow}>
					<View style={[styles.progressDot, styles.progressDotActive]} />
					<View style={styles.progressDot} />
					<View style={styles.progressDot} />
					<View style={styles.progressDot} />
				</View>

				<Text style={styles.title}>Choose a server</Text>
				<Text style={styles.subtitle}>
					Connect to your desktop Codex server first. After that, we guide you through workspace, thread, and chat.
				</Text>

				<View style={styles.card}>
					<Text style={styles.cardTitle}>Current connection</Text>
					<Text style={styles.cardDescription}>
						{hasCurrentConnection
							? String(config.baseUrl)
							: "No saved server yet."}
					</Text>
					<Pressable
						disabled={!hasCurrentConnection}
						onPress={continueWithCurrent}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							!hasCurrentConnection ? styles.disabledButton : null,
						]}
					>
						<Text style={styles.primaryButtonLabel}>Continue with current server</Text>
					</Pressable>
				</View>

				<View style={styles.card}>
					<View style={styles.cardHeaderRow}>
						<Text style={styles.cardTitle}>Discovered servers</Text>
						<Pressable
							onPress={() => {
								void scanServers();
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
						>
							<Text style={styles.secondaryButtonLabel}>{isScanning ? "Scanning..." : "Scan LAN"}</Text>
						</Pressable>
					</View>

					{isScanning ? <ActivityIndicator color={palette.accent} style={styles.loader} /> : null}

					{discoveredServers.length === 0 ? (
						<Text style={styles.emptyText}>No servers found yet. Tap Scan LAN.</Text>
					) : (
						discoveredServers.map((server) => (
							<View key={server.serverId} style={styles.serverItem}>
								<Text style={styles.serverName}>{server.hostname}:{String(server.port)}</Text>
								<Text selectable style={styles.serverUrl}>{server.baseUrl}</Text>
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
									value={tokenByServerId[server.serverId] ?? ""}
								/>
								<Pressable
									onPress={() => {
										void connectServer(server);
									}}
									style={({ pressed }) => [
										styles.primaryButton,
										pressed ? styles.primaryButtonPressed : null,
									]}
								>
									<Text style={styles.primaryButtonLabel}>
										{isConnectingByServerId[server.serverId] ? "Connecting..." : "Connect and continue"}
									</Text>
								</Pressable>
							</View>
						))
					)}
				</View>

				<View style={styles.card}>
					<Text style={styles.cardTitle}>Manual connection</Text>
					<Text style={styles.cardDescription}>
						Use this when your server is outside your LAN or when discovery is disabled.
					</Text>

					<Text style={styles.inputLabel}>Server URL</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setBaseUrl}
						placeholder="http://127.0.0.1:8835"
						placeholderTextColor={palette.muted}
						style={styles.input}
						value={baseUrl}
					/>

					<Text style={styles.inputLabel}>Token</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setToken}
						placeholder="local-dev-token"
						placeholderTextColor={palette.muted}
						style={styles.input}
						value={token}
					/>

					<Pressable
						disabled={isSaving}
						onPress={() => {
							void connectManual();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							isSaving ? styles.disabledButton : null,
						]}
					>
						<Text style={styles.primaryButtonLabel}>{isSaving ? "Connecting..." : "Connect and continue"}</Text>
					</Pressable>
				</View>

				{statusMessage ? (
					<View
						style={[
							styles.statusContainer,
							statusTone === "success" ? styles.statusSuccess : null,
							statusTone === "error" ? styles.statusError : null,
						]}
					>
						<Text style={styles.statusText}>{statusMessage}</Text>
					</View>
				) : null}
			</ScrollView>
		</KeyboardAvoidingView>
	);
};

const styles = StyleSheet.create({
	card: {
		backgroundColor: palette.card,
		borderColor: palette.line,
		borderRadius: 20,
		borderWidth: 1,
		padding: 16,
	},
	cardDescription: {
		color: palette.muted,
		fontSize: 14,
		lineHeight: 20,
		marginTop: 4,
	},
	cardHeaderRow: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
	},
	cardTitle: {
		color: palette.text,
		fontSize: 17,
		fontWeight: "700",
	},
	content: {
		gap: 16,
		paddingBottom: 36,
		paddingHorizontal: 18,
		paddingTop: 20,
	},
	disabledButton: {
		opacity: 0.45,
	},
	emptyText: {
		color: palette.muted,
		fontSize: 14,
		marginTop: 12,
	},
	headerRow: {
		alignItems: "center",
		flexDirection: "row",
	},
	input: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		color: palette.text,
		fontSize: 16,
		minHeight: 46,
		paddingHorizontal: 14,
		paddingVertical: 10,
	},
	inputLabel: {
		color: palette.muted,
		fontSize: 12,
		fontWeight: "700",
		letterSpacing: 0.5,
		marginBottom: 6,
		marginTop: 12,
		textTransform: "uppercase",
	},
	loader: {
		marginTop: 12,
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 14,
		justifyContent: "center",
		marginTop: 12,
		minHeight: 46,
		paddingHorizontal: 14,
	},
	primaryButtonLabel: {
		color: "#062016",
		fontSize: 15,
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
	secondaryButton: {
		alignItems: "center",
		borderColor: palette.line,
		borderRadius: 12,
		borderWidth: 1,
		justifyContent: "center",
		minHeight: 42,
		paddingHorizontal: 14,
	},
	secondaryButtonLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "700",
	},
	secondaryButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.1)",
	},
	serverItem: {
		backgroundColor: palette.cardSoft,
		borderColor: palette.line,
		borderRadius: 16,
		borderWidth: 1,
		gap: 8,
		marginTop: 12,
		padding: 12,
	},
	serverName: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "700",
	},
	serverUrl: {
		color: palette.muted,
		fontSize: 12,
	},
	statusContainer: {
		backgroundColor: "rgba(255,255,255,0.08)",
		borderColor: palette.line,
		borderRadius: 14,
		borderWidth: 1,
		padding: 12,
	},
	statusError: {
		borderColor: "rgba(255, 118, 133, 0.35)",
	},
	statusSuccess: {
		borderColor: "rgba(109, 227, 194, 0.35)",
	},
	statusText: {
		color: palette.text,
		fontSize: 13,
		lineHeight: 18,
	},
	stepLabel: {
		color: palette.muted,
		fontSize: 11,
		fontWeight: "700",
		letterSpacing: 1.2,
	},
	subtitle: {
		color: palette.muted,
		fontSize: 15,
		lineHeight: 22,
	},
	title: {
		color: palette.text,
		fontSize: 30,
		fontWeight: "800",
		letterSpacing: 0.3,
	},
});
