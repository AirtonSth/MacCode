import {
	createPrivateClient,
	type PrivateConnectorDto,
	type PrivateSessionDto,
} from "@remotecode/contracts";
import type { CameraViewProps } from "expo-camera";
import * as Linking from "expo-linking";
import { useGlobalSearchParams, useRouter } from "expo-router";
import { useCallback, useEffect, useMemo, useState, type ComponentType } from "react";
import {
	ActivityIndicator,
	Platform,
	Pressable,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";

import { usePrivateSession } from "../../../shared/api/private-session-provider";
import {
	DEFAULT_PRIVATE_BACKEND_URL,
	parsePrivateConnectInput,
	toPrivateConnectErrorMessage,
} from "../../../shared/api/private-mobile-connect";
import {
	buildPrivateForgotPasswordUrl,
	buildPrivateManageSubscriptionUrl,
	buildPrivateRegisterUrl,
	getPrivateSubscriptionSnapshot,
	refreshPrivateAccountSessionRecord,
	loginPrivateAccount,
	loadPrivateConnectorsSafely,
	persistSavedPrivateConnection,
	resolvePendingPrivateConnector,
	sortPrivateConnectors,
} from "./private-account-section.model";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

const areConnectorsEqual = (left: PrivateConnectorDto[], right: PrivateConnectorDto[]): boolean => {
	if (left.length !== right.length) {
		return false;
	}

	return left.every((leftConnector, index) => {
		const rightConnector = right[index];
		return (
			leftConnector.id === rightConnector.id
			&& leftConnector.name === rightConnector.name
			&& leftConnector.hostname === rightConnector.hostname
			&& leftConnector.status === rightConnector.status
			&& leftConnector.isOnline === rightConnector.isOnline
			&& leftConnector.lastSeenAt === rightConnector.lastSeenAt
			&& leftConnector.claimedAt === rightConnector.claimedAt
			&& leftConnector.relayCapabilitiesVersion === rightConnector.relayCapabilitiesVersion
			&& leftConnector.relayVersion === rightConnector.relayVersion
		);
	});
};

export const PrivateAccountSection = ({
	onConnected,
	onConnectorsLoaded = undefined,
	onPrivateConnectionSaved = undefined,
	shouldShowConnectorList = false,
}: {
	onConnected: () => void;
	onConnectorsLoaded?: (connectors: PrivateConnectorDto[]) => void;
	onPrivateConnectionSaved?: () => void;
	shouldShowConnectorList?: boolean;
}) => {
	const routeParams = useGlobalSearchParams<{
		privateConnectError?: string | string[];
	}>();
	const router = useRouter();
	const {
		activateConnector,
		clearPendingQrPayload,
		clearSessionRecord,
		pendingQrPayload,
		refreshSession,
		sessionRecord,
		setPendingQrPayload,
		setSessionRecord,
	} = usePrivateSession();
	const [backendUrl, setBackendUrl] = useState(sessionRecord?.backendUrl ?? pendingQrPayload?.backendUrl ?? DEFAULT_PRIVATE_BACKEND_URL);
	const [connectors, setConnectors] = useState<PrivateConnectorDto[]>([]);
	const [cameraLoadError, setCameraLoadError] = useState<string | null>(null);
	const [cameraView, setCameraView] = useState<ComponentType<CameraViewProps> | null>(null);
	const [email, setEmail] = useState("");
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [isAuthenticating, setIsAuthenticating] = useState(false);
	const [isLoadingConnectors, setIsLoadingConnectors] = useState(false);
	const [isScannerOpen, setIsScannerOpen] = useState(false);
	const [password, setPassword] = useState("");
	const pendingConnectorId = pendingQrPayload?.connectorId ?? null;
	const subscriptionSnapshot = useMemo(
		() => getPrivateSubscriptionSnapshot(sessionRecord?.session),
		[sessionRecord?.session],
	);
	const mobilePlatform = Platform.OS === "android" ? "android" : "ios";
	const registerUrl = useMemo(
		() => buildPrivateRegisterUrl({
			backendUrl,
			email,
			platform: mobilePlatform,
		}),
		[backendUrl, email, mobilePlatform],
	);
	const forgotPasswordUrl = useMemo(
		() => buildPrivateForgotPasswordUrl({
			backendUrl,
			email,
		}),
		[backendUrl, email],
	);
	const manageSubscriptionUrl = useMemo(
		() => buildPrivateManageSubscriptionUrl(),
		[],
	);
	const privateConnectError = useMemo(() => {
		const value = routeParams.privateConnectError;
		const rawValue = Array.isArray(value) ? value[0] : value;
		if (typeof rawValue !== "string") {
			return null;
		}

		const trimmed = rawValue.trim();
		return trimmed.length > 0 ? trimmed : null;
	}, [routeParams.privateConnectError]);
	const scannerButtonLabel = useMemo(() => {
		if (cameraLoadError) {
			return "Camera Unavailable";
		}

		if (!cameraView) {
			return "Loading Camera";
		}

		return isScannerOpen ? "Close Scanner" : "Scan QR";
	}, [cameraLoadError, cameraView, isScannerOpen]);
	const scannerUnavailableMessage = useMemo(() => {
		if (!cameraLoadError) {
			return null;
		}

		return "QR scanner is unavailable in the current iOS build. Rebuild the dev client to restore camera access.";
	}, [cameraLoadError]);
	const CameraViewComponent = cameraView;
	const setConnectorsIfUnchanged = (nextConnectors: PrivateConnectorDto[]) => {
		setConnectors((currentConnectors) => (areConnectorsEqual(currentConnectors, nextConnectors) ? currentConnectors : nextConnectors));
	};

	const loadConnectors = useCallback(async (record = sessionRecord) => {
		if (!record) {
			setConnectorsIfUnchanged([]);
			return [];
		}

		const refreshedRecord = await refreshPrivateAccountSessionRecord({
			refreshSession,
			sessionRecord: record,
		});
		if (!refreshedRecord) {
			await clearSessionRecord();
			return [];
		}

		if (
			refreshedRecord.session.user.email !== record.session.user.email
			|| refreshedRecord.session.user.subscribed !== record.session.user.subscribed
		) {
			await setSessionRecord(refreshedRecord);
		}

		if (!refreshedRecord.session.user.subscribed) {
			setConnectorsIfUnchanged([]);
			return [];
		}

		setIsLoadingConnectors(true);
		try {
			const createClient = (accessToken: string) => createPrivateClient({
				baseUrl: refreshedRecord.backendUrl,
				getAccessToken: () => accessToken,
			});

			try {
				const response = await createClient(refreshedRecord.session.accessToken).listConnectors();
				const next = sortPrivateConnectors(response.connectors);
				setConnectorsIfUnchanged(next);
				return next;
			} catch (error) {
				if (!(error instanceof Error)) {
					throw error;
				}

				const refreshed = await refreshSession();
				if (!refreshed) {
					throw error;
				}

				const response = await createClient(refreshed.accessToken).listConnectors();
				const next = sortPrivateConnectors(response.connectors);
				setConnectorsIfUnchanged(next);
				return next;
			}
		} finally {
			setIsLoadingConnectors(false);
		}
	}, [clearSessionRecord, refreshSession, sessionRecord, setSessionRecord]);

	const connectConnector = useCallback(async (
		connector: Pick<PrivateConnectorDto, "id" | "name">,
		options?: {
			sessionRecordOverride?: {
				backendUrl: string;
				session: PrivateSessionDto;
			};
			targetBackendUrl?: string;
		},
	) => {
		const targetBackendUrl = options?.targetBackendUrl ?? sessionRecord?.backendUrl ?? backendUrl;
		await activateConnector({
			backendUrl: targetBackendUrl,
			connectorId: connector.id,
			sessionRecordOverride: options?.sessionRecordOverride,
		});
		await persistSavedPrivateConnection({
			backendUrl: targetBackendUrl,
			connector,
		});
		onPrivateConnectionSaved?.();
		setErrorMessage(null);
		await clearPendingQrPayload();
		onConnected();
	}, [activateConnector, backendUrl, clearPendingQrPayload, onConnected, onPrivateConnectionSaved, sessionRecord?.backendUrl]);

	const resumePendingQrConnection = useCallback(async (candidateConnectors: PrivateConnectorDto[]) => {
		if (!pendingQrPayload || !sessionRecord || pendingQrPayload.backendUrl !== sessionRecord.backendUrl) {
			return;
		}

		const connector = resolvePendingPrivateConnector({
			connectors: candidateConnectors,
			pendingConnectorId,
		});
		if (!connector) {
			setErrorMessage("Scanned connector is not available on this account.");
			return;
		}

		await connectConnector(connector, {
			targetBackendUrl: pendingQrPayload.backendUrl,
		});
	}, [connectConnector, pendingConnectorId, pendingQrPayload, sessionRecord]);

	useEffect(() => {
		void loadPrivateConnectorsSafely({
			loadConnectors,
			onError: (message) => {
				setErrorMessage(message);
			},
			resumePendingQrConnection,
		});
	}, [loadConnectors, resumePendingQrConnection]);

	useEffect(() => {
		if (privateConnectError) {
			setErrorMessage(privateConnectError);
		}
	}, [privateConnectError]);

	useEffect(() => {
		onConnectorsLoaded?.(connectors);
	}, [connectors, onConnectorsLoaded]);

	useEffect(() => {
		let isCancelled = false;

		void (async () => {
			try {
				const cameraModule = await import("expo-camera");
				if (isCancelled) {
					return;
				}

				setCameraView(() => cameraModule.CameraView);
				setCameraLoadError(null);
			} catch (error: unknown) {
				if (isCancelled) {
					return;
				}

				setCameraView(null);
				setCameraLoadError(error instanceof Error ? error.message : "ExpoCamera native module is unavailable.");
			}
		})();

		return () => {
			isCancelled = true;
		};
	}, []);

	const handleAuthenticate = useCallback(async () => {
		setIsAuthenticating(true);
		setErrorMessage(null);
		try {
			const session = await loginPrivateAccount({
				baseUrl: backendUrl,
				email,
				password,
			});
			await setSessionRecord({
				backendUrl,
				session,
			});
			if (!session.user.subscribed) {
				setConnectorsIfUnchanged([]);
				return;
			}
			const nextConnectors = await loadConnectors({
				backendUrl,
				session,
			});
			if (pendingQrPayload && pendingQrPayload.backendUrl === backendUrl) {
				const connector = resolvePendingPrivateConnector({
					connectors: nextConnectors,
					pendingConnectorId,
				});
				if (connector) {
					await connectConnector(connector, {
						sessionRecordOverride: {
							backendUrl,
							session,
						},
						targetBackendUrl: backendUrl,
					});
					return;
				}
			}
			await resumePendingQrConnection(nextConnectors);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to authenticate private account.");
		} finally {
			setIsAuthenticating(false);
		}
	}, [
		backendUrl,
		connectConnector,
		email,
		loadConnectors,
		password,
		pendingConnectorId,
		pendingQrPayload,
		resumePendingQrConnection,
		setSessionRecord,
	]);

	const handleLogout = useCallback(async () => {
		setErrorMessage(null);
		try {
			if (sessionRecord) {
				const client = createPrivateClient({
					baseUrl: sessionRecord.backendUrl,
					getAccessToken: () => sessionRecord.session.accessToken,
				});
				await client.logout({
					refreshToken: sessionRecord.session.refreshToken,
				});
			}
		} catch {
			// best effort
		} finally {
			await clearPendingQrPayload();
			await clearSessionRecord();
			setConnectorsIfUnchanged([]);
		}
	}, [clearPendingQrPayload, clearSessionRecord, sessionRecord]);

	const scannerHelpText = useMemo(() => {
		if (pendingQrPayload) {
			return `Pending QR: ${pendingQrPayload.connectorName}`;
		}

		return "Scan the QR shown on desktop to connect instantly.";
	}, [pendingQrPayload]);
	const authenticateButtonLabel = useMemo(() => {
		if (isAuthenticating) {
			return "Working...";
		}

		return "Log in";
	}, [isAuthenticating]);
	const handleScannedQr = useCallback((rawValue: string) => {
		try {
			const intent = parsePrivateConnectInput(rawValue);
			if (intent.kind === "claim") {
				setIsScannerOpen(false);
				setErrorMessage(null);
				router.push({
					params: {
						url: intent.rawValue,
					},
					pathname: "/connect" as never,
				});
				return;
			}

			setBackendUrl(intent.payload.backendUrl);
			void setPendingQrPayload(intent.payload);
			setIsScannerOpen(false);
			setErrorMessage("QR captured. Finish sign-in or choose the connector below.");
		} catch (error) {
			setErrorMessage(toPrivateConnectErrorMessage(error));
		}
	}, [router, setPendingQrPayload]);

	return (
		<View style={styles.section}>
			<View style={styles.sectionHeader}>
				<View>
					<Text style={styles.sectionTitle}>Private Account</Text>
					<Text selectable style={styles.supportText}>
						{sessionRecord?.session.user.email ?? "Sign in to sync desktop and mobile."}
					</Text>
				</View>
				{sessionRecord ? (
					<Pressable
						onPress={() => {
							void handleLogout();
						}}
						style={({ pressed }) => [styles.secondaryButton, pressed ? styles.secondaryButtonPressed : null]}
						testID="private-account-logout"
					>
						<Text style={styles.secondaryLabel}>Logout</Text>
					</Pressable>
				) : null}
			</View>

			{sessionRecord ? (
				<View style={styles.formBody}>
					<View style={styles.accountSummary}>
						<Text style={styles.summaryLabel}>Private access</Text>
						<Text selectable style={styles.summaryValue}>{sessionRecord.session.user.email}</Text>
						<Text style={styles.supportText}>
							{subscriptionSnapshot.isSubscribed
								? `${String(subscriptionSnapshot.daysRemaining)} days remaining`
								: "Subscription inactive"}
						</Text>
						<View style={styles.subscriptionBadgeRow}>
							<View
								style={[
									styles.subscriptionBadge,
									subscriptionSnapshot.isSubscribed ? styles.subscriptionBadgeActive : styles.subscriptionBadgeInactive,
								]}
							>
								<Text style={styles.subscriptionBadgeLabel}>
									{subscriptionSnapshot.isSubscribed ? "Subscribed" : "Subscription required"}
								</Text>
							</View>
						</View>
					</View>
					{subscriptionSnapshot.isSubscribed ? (
						<>
							<View style={styles.inlineActions}>
								<Pressable
									disabled={!cameraView}
									onPress={() => {
										setIsScannerOpen((current) => !current);
									}}
									style={({ pressed }) => [
										styles.secondaryButton,
										styles.inlineButton,
										pressed ? styles.secondaryButtonPressed : null,
										!cameraView ? styles.disabledButton : null,
									]}
									testID="private-account-scan-qr"
								>
									<Text style={styles.secondaryLabel}>{scannerButtonLabel}</Text>
								</Pressable>
							</View>
							{scannerUnavailableMessage ? <Text style={styles.supportText}>{scannerUnavailableMessage}</Text> : null}

							{isScannerOpen && CameraViewComponent ? (
								<View style={styles.scannerCard} testID="private-account-qr-scanner">
									<CameraViewComponent
										barcodeScannerSettings={{
											barcodeTypes: ["qr"],
										}}
										onBarcodeScanned={(event) => {
											handleScannedQr(event.data);
										}}
										style={styles.camera}
									/>
									<Text style={styles.supportText}>{scannerHelpText}</Text>
								</View>
							) : null}

							{shouldShowConnectorList ? (
								<View style={styles.connectorList}>
									<Text style={styles.summaryLabel}>Your Servers</Text>
									{isLoadingConnectors ? <ActivityIndicator color={palette.accent} size="small" /> : null}
									{connectors.length === 0 && !isLoadingConnectors ? (
										<Text style={styles.supportText}>No private connectors found for this account yet.</Text>
									) : null}
									{connectors.map((connector, index) => (
										<Pressable
											key={connector.id}
											onPress={() => {
												void connectConnector(connector);
											}}
											style={({ pressed }) => [
												styles.connectorRow,
												pressed ? styles.connectorRowPressed : null,
											]}
											testID={`private-account-connector-${String(index)}`}
										>
											<View style={styles.rowTextGroup}>
												<Text style={styles.rowTitle}>{connector.name}</Text>
												<Text selectable style={styles.rowMeta}>
													{connector.hostname} · {connector.status}
												</Text>
											</View>
											<Text style={styles.secondaryLabel}>Connect</Text>
										</Pressable>
									))}
								</View>
							) : null}
						</>
					) : (
						<View style={styles.subscribeCard} testID="private-account-subscribe-cta">
							<Text style={styles.subscribeEyebrow}>Subscription required</Text>
							<Text style={styles.subscribeTitle}>Unlock desktop pairing on mobile</Text>
							<Text style={styles.supportText}>
								Subscribe to scan desktop QR codes, connect private connectors, and keep sync active on this device.
							</Text>
							<Pressable
								onPress={() => {
									void Linking.openURL(manageSubscriptionUrl);
								}}
								style={({ pressed }) => [
									styles.primaryButton,
									pressed ? styles.primaryButtonPressed : null,
								]}
								testID="private-account-subscribe-link"
							>
								<Text style={styles.primaryLabel}>Manage subscription</Text>
							</Pressable>
						</View>
					)}
				</View>
			) : (
				<View style={styles.formBody}>
					<TextInput
						autoCapitalize="none"
						keyboardType="email-address"
						onChangeText={setEmail}
						placeholder="dev@example.com"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="private-account-email"
						value={email}
					/>
					<TextInput
						onChangeText={setPassword}
						placeholder="Password"
						placeholderTextColor={palette.muted}
						secureTextEntry
						style={styles.input}
						testID="private-account-password"
						value={password}
					/>
					<Pressable
						disabled={isAuthenticating || backendUrl.trim().length === 0 || email.trim().length === 0 || password.trim().length === 0}
						onPress={() => {
							void handleAuthenticate();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							isAuthenticating ? styles.disabledButton : null,
						]}
						testID="private-account-authenticate"
					>
						<Text style={styles.primaryLabel}>{authenticateButtonLabel}</Text>
					</Pressable>
					<View style={styles.inlineActions}>
						<Pressable
							onPress={() => {
								void Linking.openURL(forgotPasswordUrl);
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
							testID="private-account-forgot-password"
						>
							<Text style={styles.secondaryLabel}>Forgot password</Text>
						</Pressable>
						<Pressable
							onPress={() => {
								void Linking.openURL(registerUrl);
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
							testID="private-account-register-browser"
						>
							<Text style={styles.secondaryLabel}>Register in browser</Text>
						</Pressable>
					</View>
				</View>
			)}

			{errorMessage ? (
				<View style={styles.statusBox}>
					<Text selectable style={styles.statusText}>{errorMessage}</Text>
				</View>
			) : null}
		</View>
	);
};

const styles = StyleSheet.create({
	accountSummary: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		gap: 6,
		padding: 12,
	},
	camera: {
		borderRadius: 12,
		height: 180,
		overflow: "hidden",
		width: "100%",
	},
	connectorList: {
		gap: 8,
	},
	connectorRow: {
		alignItems: "center",
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		flexDirection: "row",
		gap: 10,
		padding: 12,
	},
	connectorRowPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	disabledButton: {
		opacity: 0.45,
	},
	formBody: {
		gap: 10,
	},
	inlineActions: {
		flexDirection: "row",
		gap: 8,
	},
	inlineButton: {
		flex: 1,
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
	modeButton: {
		alignItems: "center",
		borderRadius: 10,
		flex: 1,
		justifyContent: "center",
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	modeButtonActive: {
		backgroundColor: palette.accent,
	},
	modeButtonActiveLabel: {
		color: "#0A1D2B",
		fontSize: 13,
		fontWeight: "700",
	},
	modeButtonLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	modeButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	modeToggle: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		flexDirection: "row",
		padding: 4,
	},
	primaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 11,
		height: 40,
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
	subscribeCard: {
		backgroundColor: "rgba(250,204,21,0.08)",
		borderColor: "rgba(251,191,36,0.24)",
		borderRadius: 16,
		borderWidth: 1,
		gap: 10,
		padding: 14,
	},
	subscribeEyebrow: {
		color: "#FCD34D",
		fontSize: 12,
		fontWeight: "700",
		letterSpacing: 0.8,
		textTransform: "uppercase",
	},
	subscribeTitle: {
		color: palette.text,
		fontSize: 17,
		fontWeight: "700",
	},
	rowMeta: {
		color: palette.muted,
		fontSize: 12,
	},
	rowTextGroup: {
		flex: 1,
		gap: 4,
	},
	rowTitle: {
		color: palette.text,
		fontSize: 15,
		fontWeight: "600",
	},
	scannerCard: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		gap: 8,
		padding: 10,
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
		backgroundColor: "rgba(255,107,133,0.16)",
		borderColor: "rgba(255,107,133,0.38)",
		borderRadius: 12,
		borderWidth: 1,
		padding: 12,
	},
	statusText: {
		color: palette.text,
		fontSize: 13,
		lineHeight: 19,
	},
	subscriptionBadge: {
		borderRadius: 999,
		paddingHorizontal: 10,
		paddingVertical: 6,
	},
	subscriptionBadgeActive: {
		backgroundColor: "rgba(16,185,129,0.16)",
	},
	subscriptionBadgeInactive: {
		backgroundColor: "rgba(245,158,11,0.16)",
	},
	subscriptionBadgeLabel: {
		color: palette.text,
		fontSize: 12,
		fontWeight: "700",
	},
	subscriptionBadgeRow: {
		flexDirection: "row",
	},
	summaryLabel: {
		color: palette.muted,
		fontSize: 12,
		fontWeight: "600",
	},
	summaryValue: {
		color: palette.text,
		fontSize: 14,
		fontWeight: "600",
	},
	supportText: {
		color: palette.muted,
		fontSize: 13,
		lineHeight: 18,
	},
});
