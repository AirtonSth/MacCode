import { useLocalSearchParams, useRouter } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";
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
import { usePrivateSession } from "../../../shared/api/private-session-provider";
import { createRemoteCodeClient, isRemoteCodeUnauthorizedError } from "../../../shared/api/remotecode-client";
import { IosStackHeader } from "../../../shared/ui/ios-stack-header";
import { IosActionSheet } from "../../../shared/ui/ios-action-sheet";
import { PrivateAccountSection } from "./private-account-section";

type StatusTone = "error" | "neutral" | "success";
type SettingsScreenSearchParam = string | string[] | undefined;

interface SettingsScreenSearchParams {
	debugAutoConnect?: SettingsScreenSearchParam;
	debugAutoSendMessage?: SettingsScreenSearchParam;
	debugBaseUrl?: SettingsScreenSearchParam;
	debugChatId?: SettingsScreenSearchParam;
	debugNextPath?: SettingsScreenSearchParam;
	debugProjectId?: SettingsScreenSearchParam;
	debugToken?: SettingsScreenSearchParam;
}

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
const DEFAULT_SERVER_PORT = "8835";

const normalizeSearchParam = (value: SettingsScreenSearchParam): string | null => {
	const rawValue = Array.isArray(value) ? value[0] : value;
	if (typeof rawValue !== "string") {
		return null;
	}

	const trimmedValue = rawValue.trim();
	return trimmedValue.length > 0 ? trimmedValue : null;
};

const toBooleanSearchParam = (value: SettingsScreenSearchParam): boolean => {
	const normalized = normalizeSearchParam(value)?.toLowerCase();
	return normalized === "1" || normalized === "true" || normalized === "yes";
};

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

const toManualConnectionInput = (value: string): string => {
	const host = toHost(value);
	return host.length > 0 ? host : value.trim();
};

const toSavedConnectionKey = (connection: SavedConnection): string =>
	connection.kind === "private"
		? `private:${connection.backendUrl}:${connection.connectorId}`
		: `local:${connection.baseUrl}`;

const getSavedConnectionTitle = (connection: SavedConnection): string =>
	connection.kind === "private"
		? connection.connectorName
		: toHost(connection.baseUrl) || connection.baseUrl;

const normalizeConnectionBaseUrl = (value: string): string => {
	const trimmed = value.trim();
	if (trimmed.length === 0) {
		return "";
	}

	const withProtocol = trimmed.includes("://") ? trimmed : `http://${trimmed}`;
	const [rawProtocol = "", rawAddress = ""] = withProtocol.split("://", 2);
	const protocol = rawProtocol.trim().toLowerCase() === "https" ? "https" : "http";
	const authority = (rawAddress.split(/[/?#]/u, 1)[0] ?? "").trim();
	if (authority.length === 0) {
		return "";
	}

	const authSplitIndex = authority.lastIndexOf("@");
	const hostPort = authSplitIndex !== -1 ? authority.slice(authSplitIndex + 1) : authority;
	if (hostPort.length === 0) {
		return "";
	}

	if (hostPort.startsWith("[")) {
		const closingIndex = hostPort.indexOf("]");
		if (closingIndex <= 1) {
			return "";
		}

		const host = hostPort.slice(1, closingIndex).trim();
		if (host.length === 0) {
			return "";
		}

		const suffix = hostPort.slice(closingIndex + 1).trim();
		const candidatePort = suffix.startsWith(":") ? suffix.slice(1).trim() : "";
		const port = candidatePort.length > 0 ? candidatePort : DEFAULT_SERVER_PORT;
		if (!/^\d+$/u.test(port)) {
			return "";
		}

		return `${protocol}://[${host}]:${port}`;
	}

	const [host = "", rawPort = ""] = hostPort.split(":", 2);
	const normalizedHost = host.trim();
	if (normalizedHost.length === 0) {
		return "";
	}

	const port = rawPort.trim().length > 0 ? rawPort.trim() : DEFAULT_SERVER_PORT;
	if (!/^\d+$/u.test(port)) {
		return "";
	}

	return `${protocol}://${normalizedHost}:${port}`;
};

export const SettingsScreen = () => {
	const searchParams = useLocalSearchParams() as SettingsScreenSearchParams;
	const router = useRouter();
	const { config, update } = useApiConfig();
	const { activateConnector, clearPendingQrPayload, refreshSession, sessionRecord } = usePrivateSession();
	const [baseUrl, setBaseUrl] = useState<string>(() => toManualConnectionInput(config.baseUrl));
	const [statusTone, setStatusTone] = useState<StatusTone>("neutral");
	const [statusMessage, setStatusMessage] = useState<string>("");
	const [isScanning, setIsScanning] = useState<boolean>(false);
	const [isConnectingManual, setIsConnectingManual] = useState<boolean>(false);
	const [isConnectingByServerId, setIsConnectingByServerId] = useState<Record<string, boolean>>({});
	const [isConnectingBySavedKey, setIsConnectingBySavedKey] = useState<Record<string, boolean>>({});
	const [savedConnectionActionTarget, setSavedConnectionActionTarget] = useState<SavedConnection | null>(null);
	const [discoveredServers, setDiscoveredServers] = useState<DiscoveredServer[]>([]);
	const [savedConnections, setSavedConnections] = useState<SavedConnection[]>([]);
	const [rememberedTokenByServerId, setRememberedTokenByServerId] = useState<Record<string, string>>({});
	const ignoreSavedPressByKeyRef = useRef<Set<string>>(new Set());
	const debugAutoConnectSignatureRef = useRef<string | null>(null);
	const debugBaseUrl = normalizeSearchParam(searchParams.debugBaseUrl);
	const debugChatId = normalizeSearchParam(searchParams.debugChatId);
	const debugToken = normalizeSearchParam(searchParams.debugToken);
	const debugProjectId = normalizeSearchParam(searchParams.debugProjectId);
	const debugAutoSendMessage = normalizeSearchParam(searchParams.debugAutoSendMessage);
	const debugNextPath = normalizeSearchParam(searchParams.debugNextPath);
	const shouldDebugAutoConnect = toBooleanSearchParam(searchParams.debugAutoConnect);

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
		setDiscoveredServers([]);
		setRememberedTokenByServerId({});
		try {
			const found = await DiscoveryManager.scan();
			setDiscoveredServers(found);

			const pairs = await Promise.all(
				found.map(async (server) => {
					const storedToken = await ApiConfigStore.readTokenForServer(server.serverId);
					return [server.serverId, storedToken ?? ""] as const;
				}),
			);

			setRememberedTokenByServerId((current) => {
				const next: Record<string, string> = { ...current };
				for (const [serverId, storedToken] of pairs) {
					if (storedToken.length > 0) {
						next[serverId] = storedToken;
					}
				}
				return next;
			});
			setStatusMessage("");
		} catch (error: unknown) {
			setStatus(error instanceof Error ? error.message : "Failed to scan local network.", "error");
		} finally {
			setIsScanning(false);
		}
	}, []);

	const hydrateSavedConnections = useCallback(async () => {
		const currentSaved = await ApiConfigStore.readSavedConnections();
		if (config.activeTarget.kind === "local") {
			const normalizedBaseUrl = config.baseUrl.trim();
			const normalizedToken = config.token.trim();
			const hasActiveConnection = normalizedBaseUrl.length > 0 && normalizedToken.length > 0;
			const hasActiveInSavedList = currentSaved.some((item) =>
				item.kind === "local" && item.baseUrl === normalizedBaseUrl
			);

			if (hasActiveConnection && !hasActiveInSavedList) {
				const next = await ApiConfigStore.saveSavedConnection({
					baseUrl: normalizedBaseUrl,
					kind: "local",
					token: normalizedToken,
				});
				setSavedConnections(next);
				return;
			}
		}

		setSavedConnections(currentSaved);
	}, [config.activeTarget.kind, config.baseUrl, config.token]);

	const connectSavedPrivateConnection = useCallback(async (connection: Extract<SavedConnection, { kind: "private" }>) => {
		if (!sessionRecord || sessionRecord.backendUrl !== connection.backendUrl) {
			setStatus("Sign in to reconnect this private server.", "error");
			return false;
		}

		try {
			const refreshedSession = await refreshSession();
			if (!refreshedSession) {
				setStatus("Sign in to reconnect this private server.", "error");
				return false;
			}

			await activateConnector({
				backendUrl: connection.backendUrl,
				connectorId: connection.connectorId,
				sessionRecordOverride: {
					backendUrl: connection.backendUrl,
					session: refreshedSession,
				},
			});
			await clearPendingQrPayload();
			const next = await ApiConfigStore.saveSavedConnection({
				backendUrl: connection.backendUrl,
				connectorId: connection.connectorId,
				connectorName: connection.connectorName,
				kind: "private",
			});
			setSavedConnections(next);
			setStatus("Private server connected.", "success");
			return true;
		} catch (error: unknown) {
			setStatus(error instanceof Error ? error.message : "Unable to connect to private server.", "error");
			return false;
		}
	}, [activateConnector, clearPendingQrPayload, refreshSession, sessionRecord]);

	useEffect(() => {
		void scanLan();
	}, [scanLan]);

	useEffect(() => {
		void hydrateSavedConnections();
	}, [hydrateSavedConnections]);

	const promptForServerToken = useCallback(async (): Promise<string | null> => {
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
	}, []);

	const connectAndPersist = useCallback(async (input: { baseUrl: string; token?: string; serverId?: string }) => {
		const normalizedBaseUrl = normalizeConnectionBaseUrl(input.baseUrl);
		const requestedToken = input.token?.trim() ?? "";

		if (!normalizedBaseUrl) {
			setStatus("Server address is invalid.", "error");
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
			const next = await ApiConfigStore.saveSavedConnection({
				baseUrl: normalizedBaseUrl,
				kind: "local",
				token: candidateToken,
			});
			setSavedConnections(next);
			await update({
				baseUrl: normalizedBaseUrl,
				token: candidateToken,
			});

			setBaseUrl(toManualConnectionInput(normalizedBaseUrl));
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
	}, [config.token, promptForServerToken, update]);

	const connectManual = async () => {
		setIsConnectingManual(true);
		setSavedConnectionActionTarget(null);
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
		const connectionKey = toSavedConnectionKey(connection);
		setSavedConnectionActionTarget(null);
		setIsConnectingBySavedKey((current) => ({ ...current, [connectionKey]: true }));
		setStatusMessage("");
		const connected = connection.kind === "private"
			? await connectSavedPrivateConnection(connection)
			: await connectAndPersist({
				baseUrl: connection.baseUrl,
				token: connection.token,
			});
		setIsConnectingBySavedKey((current) => ({ ...current, [connectionKey]: false }));
		if (connected) {
			goNext();
		}
	};

	const deleteSavedConnection = async (connection: SavedConnection) => {
		const next = await ApiConfigStore.deleteSavedConnection(connection);
		setSavedConnections(next);
		setSavedConnectionActionTarget((current) =>
			current && toSavedConnectionKey(current) === toSavedConnectionKey(connection) ? null : current,
		);
	};

	const connectDiscoveredServer = async (server: DiscoveredServer) => {
		const rememberedToken = (rememberedTokenByServerId[server.serverId] ?? "").trim();
		setSavedConnectionActionTarget(null);
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

	useEffect(() => {
		if (!shouldDebugAutoConnect || !debugBaseUrl || isConnectingManual) {
			return;
		}

		const signature = `${debugBaseUrl}::${debugToken ?? ""}::${debugNextPath ?? ""}`;
		if (debugAutoConnectSignatureRef.current === signature) {
			return;
		}

		debugAutoConnectSignatureRef.current = signature;
		setIsConnectingManual(true);
		setStatusMessage("");
		console.log("[settings-debug] auto-connecting from route", {
			baseUrl: debugBaseUrl,
			hasToken: Boolean(debugToken),
			nextPath: debugNextPath ?? "/workspaces",
		});

		void (async () => {
			try {
				const connected = await connectAndPersist({
					baseUrl: debugBaseUrl,
					token: debugToken ?? undefined,
				});
				if (!connected) {
					debugAutoConnectSignatureRef.current = null;
					console.log("[settings-debug] auto-connect deferred", {
						baseUrl: debugBaseUrl,
					});
					return;
				}

				console.log("[settings-debug] auto-connect complete", {
					chatId: debugChatId,
					baseUrl: debugBaseUrl,
					nextPath: debugNextPath ?? "/workspaces",
					projectId: debugProjectId,
				});
				if (debugProjectId && debugChatId) {
					router.replace({
						pathname: "/chat",
						params: {
							chatId: debugChatId,
							debugAutoSendMessage: debugAutoSendMessage ?? undefined,
							projectId: debugProjectId,
							source: "thread-list",
						},
					});
					return;
				}

				router.replace("/workspaces");
			} catch (error: unknown) {
				debugAutoConnectSignatureRef.current = null;
				console.log("[settings-debug] auto-connect failed", {
					baseUrl: debugBaseUrl,
					error: error instanceof Error ? error.message : "unknown-error",
				});
			} finally {
				setIsConnectingManual(false);
			}
		})();
	}, [
		debugBaseUrl,
		debugChatId,
		debugAutoSendMessage,
		connectAndPersist,
		debugNextPath,
		debugProjectId,
		debugToken,
		isConnectingManual,
		router,
		shouldDebugAutoConnect,
	]);

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
							data={savedConnections}
							keyExtractor={(item) => toSavedConnectionKey(item)}
							renderItem={({ item: connection, index }) => {
								const connectionKey = toSavedConnectionKey(connection);
								const isConnecting = Boolean(isConnectingBySavedKey[connectionKey]);

								return (
									<Pressable
										accessibilityLabel={`Connect saved server ${getSavedConnectionTitle(connection)}`}
										delayLongPress={280}
										disabled={isConnecting}
										onLongPress={() => {
											if (isConnecting) {
												return;
											}

											ignoreSavedPressByKeyRef.current.add(connectionKey);
											setSavedConnectionActionTarget(connection);
										}}
										onPress={() => {
											if (ignoreSavedPressByKeyRef.current.has(connectionKey)) {
												ignoreSavedPressByKeyRef.current.delete(connectionKey);
												return;
											}

											void connectSavedConnection(connection);
										}}
										onPressOut={() => {
											if (!ignoreSavedPressByKeyRef.current.has(connectionKey)) {
												return;
											}

											setTimeout(() => {
												ignoreSavedPressByKeyRef.current.delete(connectionKey);
											}, 0);
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
												{getSavedConnectionTitle(connection)}
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
						ListEmptyComponent={<Text style={styles.supportText}>No saved connection.</Text>}
						contentContainerStyle={styles.connectionList}
						removeClippedSubviews={false}
						scrollEnabled={false}
						showsVerticalScrollIndicator={false}
					/>
				</View>
				<View style={styles.sectionDivider} />
				<PrivateAccountSection
					onConnected={() => {
						goNext();
					}}
					onPrivateConnectionSaved={() => {
						void hydrateSavedConnections();
					}}
				/>
				<View style={styles.sectionDivider} />

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
												{server.hostname || toHost(server.baseUrl) || server.baseUrl}
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
						<View style={styles.manualConnectionRow}>
							<TextInput
								autoCapitalize="none"
								onChangeText={setBaseUrl}
								placeholder="127.0.0.1"
								placeholderTextColor={palette.muted}
								style={[styles.input, styles.manualConnectionInput]}
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
									styles.manualConnectionButton,
									pressed ? styles.primaryButtonPressed : null,
									isConnectingManual ? styles.disabledButton : null,
								]}
								testID="server-manual-connect"
							>
								<Text style={styles.primaryLabel}>{isConnectingManual ? "Connecting..." : "Connect"}</Text>
							</Pressable>
						</View>
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
				<IosActionSheet
					actions={[
						{
							icon: "delete-outline",
							key: "delete-saved-connection",
							label: "Delete",
							onPress: () => {
								if (!savedConnectionActionTarget) {
									return;
								}
								void deleteSavedConnection(savedConnectionActionTarget);
							},
							testID: "saved-server-delete",
							tone: "destructive",
						},
					]}
					onClose={() => {
						setSavedConnectionActionTarget(null);
					}}
					testID="saved-server-action-sheet"
					title={
						savedConnectionActionTarget
							? getSavedConnectionTitle(savedConnectionActionTarget)
							: "Connection options"
					}
					isVisible={savedConnectionActionTarget !== null}
				/>
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
	sectionDivider: {
		backgroundColor: "rgba(255,255,255,0.12)",
		height: StyleSheet.hairlineWidth,
		marginVertical: 2,
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
	manualConnectionButton: {
		minWidth: 108,
	},
	manualConnectionInput: {
		flex: 1,
	},
	manualConnectionRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 10,
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
