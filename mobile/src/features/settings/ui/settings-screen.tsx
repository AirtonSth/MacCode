import { useRouter } from "expo-router";
import { useEffect, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, Text, TextInput, View } from "react-native";

import { useApiConfig } from "../../../shared/api/api-config-provider";
import { ApiConfigStore } from "../../../shared/api/api-config-store";
import { createRemoteCodeClient } from "../../../shared/api/remotecode-client";
import { DiscoveryManager, type DiscoveredServer } from "../../../shared/api/discovery-manager";
import { theme } from "../../../shared/theme/tokens";
import { GlassPanel } from "../../../shared/ui/glass-panel";

export const SettingsScreen = () => {
	const { config, update } = useApiConfig();
	const router = useRouter();
	const [baseUrl, setBaseUrl] = useState<string>(config.baseUrl);
	const [token, setToken] = useState<string>(config.token);
	const [isSaving, setIsSaving] = useState<boolean>(false);
	const [saved, setSaved] = useState<boolean>(false);
	const [discoveredServers, setDiscoveredServers] = useState<DiscoveredServer[]>([]);
	const [tokenByServerId, setTokenByServerId] = useState<Record<string, string>>({});
	const [isScanning, setIsScanning] = useState<boolean>(false);
	const [isConnectingByServerId, setIsConnectingByServerId] = useState<Record<string, boolean>>({});
	const [statusMessage, setStatusMessage] = useState<string | null>(null);

	const save = async () => {
		setIsSaving(true);
		setSaved(false);
		setStatusMessage(null);
		await update({
			baseUrl,
			token,
		});
		setSaved(true);
		setIsSaving(false);
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
			for (const [serverId, serverToken] of tokenPairs) {
				next[serverId] = serverToken;
			}
			return next;
		});
	};

	useEffect(() => {
		void loadRecent();
	}, []);

	const scanServers = async () => {
		setIsScanning(true);
		setStatusMessage(null);

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
				for (const [serverId, serverToken] of tokenPairs) {
					next[serverId] = current[serverId] ?? serverToken;
				}
				return next;
			});
		} catch (error) {
			setStatusMessage(error instanceof Error ? error.message : "Unable to scan the local network.");
		} finally {
			setIsScanning(false);
		}
	};

	const connectServer = async (server: DiscoveredServer) => {
		const selectedToken = (tokenByServerId[server.serverId] ?? "").trim() || token.trim();
		if (!selectedToken) {
			setStatusMessage("Token is required to connect to the selected server.");
			return;
		}

		setIsConnectingByServerId((current) => ({
			...current,
			[server.serverId]: true,
		}));
		setStatusMessage(null);

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
			setSaved(true);
			setStatusMessage(`Connected to ${server.hostname}:${String(server.port)}`);
		} catch (error) {
			setStatusMessage(error instanceof Error ? error.message : "Unable to connect to selected server.");
		} finally {
			setIsConnectingByServerId((current) => ({
				...current,
				[server.serverId]: false,
			}));
		}
	};

	return (
		<ScrollView
			contentContainerStyle={{
				flexGrow: 1,
				gap: 14,
				padding: 16,
			}}
			contentInsetAdjustmentBehavior="automatic"
			style={{
				backgroundColor: theme.colors.background,
				flex: 1,
			}}
		>
			<GlassPanel>
				<View
					style={{
						alignItems: "center",
						flexDirection: "row",
						justifyContent: "space-between",
					}}
				>
					<Text
						style={{
							color: theme.colors.textPrimary,
							fontSize: 22,
							fontWeight: "700",
						}}
					>
						Servers
					</Text>
					<Pressable
						onPress={() => {
							void scanServers();
						}}
						style={({ pressed }) => ({
							backgroundColor: pressed ? "rgba(99,200,255,0.3)" : "rgba(99,200,255,0.18)",
							borderColor: "rgba(99,200,255,0.35)",
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							paddingHorizontal: 14,
							paddingVertical: 8,
						})}
					>
						<Text
							style={{
								color: theme.colors.textPrimary,
								fontSize: 13,
								fontWeight: "700",
							}}
						>
							{isScanning ? "Scanning..." : "Scan LAN"}
						</Text>
					</Pressable>
				</View>

				<Text
					style={{
						color: theme.colors.textSecondary,
						fontSize: 13,
						marginTop: 6,
					}}
				>
					Discover local desktop servers on port 8835 and connect using token auth.
				</Text>

				{isScanning ? <ActivityIndicator color={theme.colors.accent} style={{ marginTop: 10 }} /> : null}

				<View style={{ gap: 10, marginTop: 12 }}>
					{discoveredServers.length === 0 ? (
						<Text style={{ color: theme.colors.muted, fontSize: 13 }}>
							No servers discovered yet. Tap Scan LAN.
						</Text>
					) : null}
					{discoveredServers.map((server) => (
						<View
							key={server.serverId}
							style={{
								backgroundColor: "rgba(255,255,255,0.03)",
								borderColor: theme.colors.borderSoft,
								borderRadius: theme.borderRadius.card,
								borderWidth: 1,
								padding: 10,
							}}
						>
							<Text style={{ color: theme.colors.textPrimary, fontSize: 14, fontWeight: "700" }}>
								{server.hostname}:{String(server.port)}
							</Text>
							<Text style={{ color: theme.colors.muted, fontSize: 12, marginTop: 4 }} selectable>
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
								placeholder="Token"
								placeholderTextColor={theme.colors.muted}
								style={{
									backgroundColor: "rgba(255,255,255,0.04)",
									borderColor: theme.colors.borderSoft,
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
									color: theme.colors.textPrimary,
									fontSize: 13,
									marginTop: 8,
									paddingHorizontal: 10,
									paddingVertical: 8,
								}}
								value={tokenByServerId[server.serverId] ?? ""}
							/>
							<Pressable
								onPress={() => {
									void connectServer(server);
								}}
								style={({ pressed }) => ({
									backgroundColor: pressed ? "rgba(99,200,255,0.3)" : "rgba(99,200,255,0.18)",
									borderColor: "rgba(99,200,255,0.35)",
									borderRadius: theme.borderRadius.chip,
									borderWidth: 1,
									marginTop: 8,
									paddingHorizontal: 12,
									paddingVertical: 8,
								})}
							>
								<Text style={{ color: theme.colors.textPrimary, fontSize: 13, fontWeight: "700" }}>
									{isConnectingByServerId[server.serverId] ? "Connecting..." : "Connect"}
								</Text>
							</Pressable>
						</View>
					))}
				</View>
			</GlassPanel>

			<GlassPanel>
				<Text
					style={{
						color: theme.colors.textPrimary,
						fontSize: 22,
						fontWeight: "700",
					}}
				>
					Manual Connection
				</Text>
				<Text
					style={{
						color: theme.colors.textSecondary,
						fontSize: 13,
						marginTop: 6,
					}}
				>
					Fallback: configure server URL and token manually.
				</Text>

				<View style={{ marginTop: 16 }}>
					<Text
						style={{
							color: theme.colors.textSecondary,
							fontSize: 12,
							marginBottom: 6,
							textTransform: "uppercase",
						}}
					>
						Server URL
					</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setBaseUrl}
						placeholder="http://127.0.0.1:8835"
						placeholderTextColor={theme.colors.muted}
						style={{
							backgroundColor: "rgba(255,255,255,0.04)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							color: theme.colors.textPrimary,
							fontSize: 14,
							paddingHorizontal: 12,
							paddingVertical: 10,
						}}
						value={baseUrl}
					/>
				</View>

				<View style={{ marginTop: 14 }}>
					<Text
						style={{
							color: theme.colors.textSecondary,
							fontSize: 12,
							marginBottom: 6,
							textTransform: "uppercase",
						}}
					>
						Token
					</Text>
					<TextInput
						autoCapitalize="none"
						onChangeText={setToken}
						placeholder="local-dev-token"
						placeholderTextColor={theme.colors.muted}
						style={{
							backgroundColor: "rgba(255,255,255,0.04)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							color: theme.colors.textPrimary,
							fontSize: 14,
							paddingHorizontal: 12,
							paddingVertical: 10,
						}}
						value={token}
					/>
				</View>

				<View style={{ flexDirection: "row", gap: 10, marginTop: 18 }}>
					<Pressable
						onPress={() => {
							void save();
						}}
						style={({ pressed }) => ({
							backgroundColor: pressed ? "rgba(99,200,255,0.3)" : "rgba(99,200,255,0.18)",
							borderColor: "rgba(99,200,255,0.35)",
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							paddingHorizontal: 16,
							paddingVertical: 10,
						})}
					>
						<Text style={{ color: theme.colors.textPrimary, fontSize: 14, fontWeight: "700" }}>
							{isSaving ? "Saving..." : "Save"}
						</Text>
					</Pressable>

					<Pressable
						onPress={() => {
							router.back();
						}}
						style={({ pressed }) => ({
							backgroundColor: pressed ? "rgba(255,255,255,0.13)" : "rgba(255,255,255,0.06)",
							borderColor: theme.colors.borderSoft,
							borderRadius: theme.borderRadius.chip,
							borderWidth: 1,
							paddingHorizontal: 16,
							paddingVertical: 10,
						})}
					>
						<Text style={{ color: theme.colors.textPrimary, fontSize: 14, fontWeight: "600" }}>
							Close
						</Text>
					</Pressable>
				</View>

				{saved ? (
					<Text
						style={{
							color: theme.colors.accent,
							fontSize: 12,
							marginTop: 10,
						}}
					>
						Saved. The app now reconnects using the new settings.
					</Text>
				) : null}

				{statusMessage ? (
					<Text
						style={{
							color: theme.colors.textSecondary,
							fontSize: 12,
							marginTop: 8,
						}}
					>
						{statusMessage}
					</Text>
				) : null}
			</GlassPanel>
		</ScrollView>
	);
};
