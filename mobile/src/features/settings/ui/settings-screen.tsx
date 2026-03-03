import { useRouter } from "expo-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
	ActivityIndicator,
	Alert,
	FlatList,
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
import { ApiConfigStore, type SavedConnection } from "../../../shared/api/api-config-store";
import { DiscoveryManager, type DiscoveredServer } from "../../../shared/api/discovery-manager";
import { createRemoteCodeClient, isRemoteCodeUnauthorizedError } from "../../../shared/api/remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { SwipeableSavedConnectionItem } from "./swipeable-saved-connection-item";

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

const DEFAULT_SERVER_TOKEN = "remotecode.io-token";

const toHost = (value: string): string => {
	const trimmed = value.trim().toLowerCase();
	if (trimmed.length === 0) {
		return "";
	}

	const withoutProtocol = trimmed.includes("://") ? trimmed.split("://", 2)[1] : trimmed;
	const withoutPath = withoutProtocol.split(/[/?#]/u, 1)[0] ?? "";
	if (withoutPath.length === 0) {
		return "";
	}

	const authSplitIndex = withoutPath.lastIndexOf("@");
	const hostPort = authSplitIndex !== -1 ? withoutPath.slice(authSplitIndex + 1) : withoutPath;
	if (hostPort.startsWith("[")) {
		const closingIndex = hostPort.indexOf("]");
		if (closingIndex > 1) {
			return hostPort.slice(1, closingIndex).trim();
		}
		return "";
	}

	return hostPort.split(":", 1)[0].trim();
};

const isPrivateIPv4 = (host: string): boolean => {
	const parts = host.split(".");
	if (parts.length !== 4) {
		return false;
	}

	const numbers = parts.map((part) => Number.parseInt(part, 10));
	if (numbers.some((part) => Number.isNaN(part) || part < 0 || part > 255)) {
		return false;
	}

	return (
		numbers[0] === 10 ||
		numbers[0] === 127 ||
		(numbers[0] === 169 && numbers[1] === 254) ||
		(numbers[0] === 172 && numbers[1] >= 16 && numbers[1] <= 31) ||
		(numbers[0] === 192 && numbers[1] === 168)
	);
};

const isLanBaseUrl = (value: string): boolean => {
	const host = toHost(value);
	if (!host) {
		return false;
	}

	if (
		host === "localhost" ||
		host === "::1" ||
		host.endsWith(".local") ||
		host.endsWith(".lan") ||
		host.endsWith(".home") ||
		host.startsWith("fe80:")
	) {
		return true;
	}

	return isPrivateIPv4(host);
};

const filterSavedConnections = (items: SavedConnection[]): SavedConnection[] =>
	items.filter((item) => !isLanBaseUrl(item.baseUrl));

export const SettingsScreen = () => {
	const router = useRouter();
	const { config, update } = useApiConfig();
	const [baseUrl, setBaseUrl] = useState<string>(config.baseUrl);
	const [statusTone, setStatusTone] = useState<StatusTone>("neutral");
	const [statusMessage, setStatusMessage] = useState<string>("");
	const [isScanning, setIsScanning] = useState<boolean>(false);
	const [isConnectingManual, setIsConnectingManual] = useState<boolean>(false);
	const [isConnectingByServerId, setIsConnectingByServerId] = useState<Record<string, boolean>>({});
	const [isConnectingBySavedBaseUrl, setIsConnectingBySavedBaseUrl] = useState<Record<string, boolean>>({});
	const [openSavedSwipeBaseUrl, setOpenSavedSwipeBaseUrl] = useState<string | null>(null);
	const [discoveredServers, setDiscoveredServers] = useState<DiscoveredServer[]>([]);
	const [savedConnections, setSavedConnections] = useState<SavedConnection[]>([]);
	const [rememberedTokenByServerId, setRememberedTokenByServerId] = useState<Record<string, string>>({});
	const visibleSavedConnections = useMemo(() => filterSavedConnections(savedConnections), [savedConnections]);

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
			setStatusMessage("");
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

		setRememberedTokenByServerId((current) => {
			const next = { ...current };
			for (const [serverId, storedToken] of pairs) {
				next[serverId] ||= storedToken;
			}
			return next;
		});
	}, []);

	const hydrateSavedConnections = useCallback(async () => {
		const currentSaved = await ApiConfigStore.readSavedConnections();
		const filteredSaved = filterSavedConnections(currentSaved);
		const normalizedBaseUrl = config.baseUrl.trim();
		const normalizedToken = config.token.trim();
		const hasActiveNonLanConnection =
			normalizedBaseUrl.length > 0 &&
			normalizedToken.length > 0 &&
			!isLanBaseUrl(normalizedBaseUrl);
		const hasActiveInSavedList = filteredSaved.some((item) => item.baseUrl === normalizedBaseUrl);

		if (hasActiveNonLanConnection && !hasActiveInSavedList) {
			const next = await ApiConfigStore.saveSavedConnection({
				baseUrl: normalizedBaseUrl,
				token: normalizedToken,
			});
			setSavedConnections(filterSavedConnections(next));
			return;
		}

		setSavedConnections(filteredSaved);
	}, [config.baseUrl, config.token]);

	useEffect(() => {
		void hydrateRecentServers();
		void scanLan();
	}, [hydrateRecentServers, scanLan]);

	useEffect(() => {
		void hydrateSavedConnections();
	}, [hydrateSavedConnections]);

	const promptForServerToken = async (): Promise<string | null> => {
		if (Platform.OS !== "ios" || typeof Alert.prompt !== "function") {
			setStatus("Server rejected the default token. Manual token prompt is available only on iOS.", "error");
			return null;
		}

		// eslint-disable-next-line promise/avoid-new -- Alert.prompt uses callbacks and does not return a Promise.
		return await new Promise((resolve) => {
			Alert.prompt(
				"Server Token Required",
				"This server rejected the default token. Enter the server token to continue.",
				[
					{
						style: "cancel",
						text: "Cancel",
						onPress: () => {
							resolve(null);
						},
					},
					{
						text: "Connect",
						onPress: (value?: string) => {
							const normalized = value?.trim() ?? "";
							resolve(normalized.length > 0 ? normalized : null);
						},
					},
				],
				"secure-text",
			);
		});
	};

	const connectAndPersist = async (input: { baseUrl: string; token?: string; serverId?: string }) => {
		const normalizedBaseUrl = input.baseUrl.trim();
		const requestedToken = input.token?.trim() ?? "";

		if (!normalizedBaseUrl) {
			setStatus("Server URL is required.", "error");
			return false;
		}

		const attemptConnection = async (candidateToken: string): Promise<boolean> => {
			const verifyClient = createRemoteCodeClient({
				baseUrl: normalizedBaseUrl,
				token: candidateToken,
			});
			await verifyClient.verifyToken(candidateToken, normalizedBaseUrl);

			const serverId = input.serverId;
			if (serverId) {
				await ApiConfigStore.saveServerConnection({
					baseUrl: normalizedBaseUrl,
					serverId,
					token: candidateToken,
				});
				setRememberedTokenByServerId((current) => ({
					...current,
					[serverId]: candidateToken,
				}));
			}
			const isLanConnection = Boolean(serverId) || isLanBaseUrl(normalizedBaseUrl);
			if (isLanConnection) {
				const next = await ApiConfigStore.deleteSavedConnection(normalizedBaseUrl);
				setSavedConnections(filterSavedConnections(next));
			} else {
				const next = await ApiConfigStore.saveSavedConnection({
					baseUrl: normalizedBaseUrl,
					token: candidateToken,
				});
				setSavedConnections(filterSavedConnections(next));
			}
			await update({
				baseUrl: normalizedBaseUrl,
				token: candidateToken,
			});

			setBaseUrl(normalizedBaseUrl);
			setStatus("Server connected.", "success");
			return true;
		};

		const tokensToTry = [DEFAULT_SERVER_TOKEN];
		const pushed = new Set<string>(tokensToTry);
		if (requestedToken.length > 0 && requestedToken !== DEFAULT_SERVER_TOKEN && !pushed.has(requestedToken)) {
			tokensToTry.push(requestedToken);
			pushed.add(requestedToken);
		}

		const persistedToken = config.token.trim();
		if (persistedToken.length > 0 && persistedToken !== DEFAULT_SERVER_TOKEN && !pushed.has(persistedToken)) {
			tokensToTry.push(persistedToken);
			pushed.add(persistedToken);
		}

	const tryWithToken = async (index: number): Promise<boolean> => {
		const token = tokensToTry[index];
		if (!token) {
			return false;
		}

		try {
			return await attemptConnection(token);
		} catch (error: unknown) {
			if (!isRemoteCodeUnauthorizedError(error)) {
				setStatus(error instanceof Error ? error.message : "Unable to connect to server.", "error");
				return false;
			}

			if (index + 1 < tokensToTry.length) {
				return await tryWithToken(index + 1);
			}
		}

		const promptToken = await promptForServerToken();
		if (!promptToken) {
			setStatus("Connection canceled.", "neutral");
			return false;
		}

		try {
			return await attemptConnection(promptToken);
		} catch (error: unknown) {
			setStatus(error instanceof Error ? error.message : "Unable to connect to server.", "error");
			return false;
		}
	};

	return await tryWithToken(0);
};

	const connectManual = async () => {
		setIsConnectingManual(true);
		setOpenSavedSwipeBaseUrl(null);
		setStatusMessage("");
		const connected = await connectAndPersist({
			baseUrl,
		});
		setIsConnectingManual(false);
		if (connected) {
			goNext();
		}
	};

	const connectSavedConnection = async (connection: SavedConnection) => {
		setOpenSavedSwipeBaseUrl(null);
		setIsConnectingBySavedBaseUrl((current) => ({ ...current, [connection.baseUrl]: true }));
		setStatusMessage("");
		const connected = await connectAndPersist({
			baseUrl: connection.baseUrl,
			token: connection.token,
		});
		setIsConnectingBySavedBaseUrl((current) => ({ ...current, [connection.baseUrl]: false }));
		if (connected) {
			goNext();
		}
	};

	const deleteSavedConnection = async (connection: SavedConnection) => {
		const next = await ApiConfigStore.deleteSavedConnection(connection.baseUrl);
		setSavedConnections(filterSavedConnections(next));
		setOpenSavedSwipeBaseUrl((current) => (current === connection.baseUrl ? null : current));
	};

	const connectDiscoveredServer = async (server: DiscoveredServer) => {
		const rememberedToken = (rememberedTokenByServerId[server.serverId] ?? "").trim();
		setOpenSavedSwipeBaseUrl(null);
		setIsConnectingByServerId((current) => ({ ...current, [server.serverId]: true }));
		setStatusMessage("");

		const connected = await connectAndPersist({
			baseUrl: server.baseUrl,
			serverId: server.serverId,
			token: rememberedToken,
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
				<IosStackHeader shouldShowBack={false} subtitle="Select server connection" title="Server" />

			<ScrollView
				contentContainerStyle={styles.content}
				contentInsetAdjustmentBehavior="automatic"
				keyboardShouldPersistTaps="handled"
				showsVerticalScrollIndicator={false}
			>
				<View style={styles.section}>
					<View style={styles.sectionHeader}>
						<Text style={styles.sectionTitle}>Saved Connections</Text>
					</View>

					<FlatList
						data={visibleSavedConnections}
						keyExtractor={(item) => item.baseUrl}
						renderItem={({ item: connection, index }) => {
							const isConnecting = Boolean(isConnectingBySavedBaseUrl[connection.baseUrl]);

							return (
								<SwipeableSavedConnectionItem
									deleteTestID={`saved-server-delete-${String(index)}`}
									index={index}
									isActive={openSavedSwipeBaseUrl === connection.baseUrl}
									onClose={() => {
										setOpenSavedSwipeBaseUrl((current) =>
											current === connection.baseUrl ? null : current,
										);
									}}
									onDelete={() => {
										void deleteSavedConnection(connection);
									}}
									onOpen={() => {
										setOpenSavedSwipeBaseUrl(connection.baseUrl);
									}}
								>
									<Pressable
										accessibilityLabel={`Connect saved server ${toHost(connection.baseUrl) || connection.baseUrl}`}
										disabled={isConnecting}
										onPress={() => {
											void connectSavedConnection(connection);
										}}
										style={({ pressed }) => [
											styles.listRow,
											index % 2 === 0 ? styles.listRowStriped : null,
											pressed ? styles.listRowPressed : null,
											isConnecting ? styles.disabledButton : null,
										]}
										testID={`saved-server-item-${String(index)}`}
									>
										<View style={styles.rowTextGroup}>
											<Text numberOfLines={1} style={styles.rowTitle}>
												{toHost(connection.baseUrl) || connection.baseUrl}
											</Text>
											<Text selectable numberOfLines={1} style={styles.rowMeta}>
												{connection.baseUrl}
											</Text>
										</View>

										{isConnecting ? (
											<ActivityIndicator color={palette.accent} size="small" />
										) : (
											<Text style={styles.disclosureSymbol}>{">"}</Text>
										)}
									</Pressable>
								</SwipeableSavedConnectionItem>
							);
						}}
						ListEmptyComponent={<Text style={styles.supportText}>No saved connection.</Text>}
						contentContainerStyle={styles.connectionList}
						removeClippedSubviews={false}
						scrollEnabled={false}
						showsVerticalScrollIndicator={false}
					/>
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
								isScanning ? styles.disabledButton : null,
							]}
							disabled={isScanning}
							testID="server-scan-button"
						>
							{isScanning ? <ActivityIndicator color={palette.text} size="small" /> : <Text style={styles.secondaryLabel}>Scan</Text>}
						</Pressable>
					</View>

					<FlatList
						data={discoveredServers}
						keyExtractor={(item) => item.serverId}
						renderItem={({ item: server, index }) => {
							const isConnecting = Boolean(isConnectingByServerId[server.serverId]);
							return (
								<Pressable
									accessibilityLabel={`Connect server ${server.hostname}:${String(server.port)}`}
									disabled={isConnecting}
									onPress={() => {
										void connectDiscoveredServer(server);
									}}
									style={({ pressed }) => [
										styles.listRow,
										index % 2 === 0 ? styles.listRowStriped : null,
										pressed ? styles.listRowPressed : null,
										isConnecting ? styles.disabledButton : null,
									]}
									testID={`server-item-${String(index)}`}
									>
										<View style={styles.rowTextGroup}>
											<Text numberOfLines={1} style={styles.rowTitle}>
												{server.hostname}:{String(server.port)}
											</Text>
											<Text selectable numberOfLines={1} style={styles.rowMeta}>
												{server.baseUrl}
											</Text>
										</View>

										{isConnecting ? (
											<ActivityIndicator color={palette.accent} size="small" />
										) : (
											<Text style={styles.disclosureSymbol}>{">"}</Text>
										)}
									</Pressable>
							);
						}}
						ListEmptyComponent={<Text style={styles.supportText}>No discovered server.</Text>}
						contentContainerStyle={styles.connectionList}
						removeClippedSubviews={false}
						scrollEnabled={false}
						showsVerticalScrollIndicator={false}
					/>
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
		alignItems: "center",
		gap: 8,
		flexDirection: "row",
		borderBottomWidth: StyleSheet.hairlineWidth,
		borderBottomColor: "rgba(255,255,255,0.18)",
		paddingBottom: 12,
		paddingTop: 12,
	},
	listRowPressed: {
		backgroundColor: "rgba(255,255,255,0.06)",
	},
	listRowStriped: {
		backgroundColor: "rgba(255,255,255,0.03)",
	},
	connectionList: {
		paddingTop: 4,
	},
	disclosureSymbol: {
		color: palette.accent,
		fontSize: 22,
		lineHeight: 22,
		fontWeight: "500",
	},
	rowTextGroup: {
		flex: 1,
		gap: 4,
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
