import {
	createPrivateClient,
	type PrivateConnectorDto,
	type PrivateSessionDto,
} from "@remotecode/contracts";
import * as Linking from "expo-linking";
import { useGlobalSearchParams } from "expo-router";
import { useCallback, useEffect, useMemo, useState } from "react";
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
import { IosActionSheet } from "../../../shared/ui/ios-action-sheet";
import {
	buildPrivacyPolicyUrl,
	buildPrivateForgotPasswordUrl,
	buildPrivateManageSubscriptionUrl,
	buildPrivateRegisterUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	getPrivateSubscriptionSnapshot,
	loginPrivateAccount,
	loadPrivateConnectorsSafely,
	persistSavedPrivateConnection,
	refreshPrivateAccountSessionRecord,
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

const DEFAULT_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787";

const areConnectorsEqual = (
	left: PrivateConnectorDto[],
	right: PrivateConnectorDto[],
): boolean => {
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

interface PrivateAccountSectionProps {
	onConnected: () => void;
	onConnectorsLoaded?: (connectors: PrivateConnectorDto[]) => void;
	onPrivateConnectionSaved?: () => void;
	shouldShowConnectorList?: boolean;
}

export const PrivateAccountSection = ({
	onConnected,
	onConnectorsLoaded = undefined,
	onPrivateConnectionSaved = undefined,
	shouldShowConnectorList = false,
}: PrivateAccountSectionProps) => {
	const routeParams = useGlobalSearchParams<{
		privateConnectError?: string | string[];
	}>();
	const {
		activateConnector,
		clearSessionRecord,
		refreshSession,
		sessionRecord,
		setSessionRecord,
	} = usePrivateSession();
	const backendUrl = sessionRecord?.backendUrl ?? DEFAULT_PRIVATE_BACKEND_URL;
	const [connectors, setConnectors] = useState<PrivateConnectorDto[]>([]);
	const [email, setEmail] = useState("");
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [isAuthenticating, setIsAuthenticating] = useState(false);
	const [isDeletingAccount, setIsDeletingAccount] = useState(false);
	const [isDeleteConfirmVisible, setIsDeleteConfirmVisible] = useState(false);
	const [isLoadingConnectors, setIsLoadingConnectors] = useState(false);
	const [password, setPassword] = useState("");
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
	const privacyPolicyUrl = useMemo(() => buildPrivacyPolicyUrl(), []);
	const termsOfUseUrl = useMemo(() => buildTermsOfUseUrl(), []);
	const privateConnectError = useMemo(() => {
		const value = routeParams.privateConnectError;
		const rawValue = Array.isArray(value) ? value[0] : value;
		if (typeof rawValue !== "string") {
			return null;
		}

		const trimmed = rawValue.trim();
		return trimmed.length > 0 ? trimmed : null;
	}, [routeParams.privateConnectError]);
	const setConnectorsIfUnchanged = (nextConnectors: PrivateConnectorDto[]) => {
		setConnectors((currentConnectors) =>
			(areConnectorsEqual(currentConnectors, nextConnectors) ? currentConnectors : nextConnectors)
		);
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
	}, [
	clearSessionRecord,
	refreshSession,
	sessionRecord,
	setSessionRecord,
]);

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
		onConnected();
	}, [
	activateConnector,
	backendUrl,
	onConnected,
	onPrivateConnectionSaved,
	sessionRecord?.backendUrl,
]);

	useEffect(() => {
		void loadPrivateConnectorsSafely({
			loadConnectors,
			onError: (message) => {
				setErrorMessage(message);
			},
		});
	}, [loadConnectors]);

	useEffect(() => {
		if (privateConnectError) {
			setErrorMessage(privateConnectError);
		}
	}, [privateConnectError]);

	useEffect(() => {
		onConnectorsLoaded?.(connectors);
	}, [connectors, onConnectorsLoaded]);

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
			await loadConnectors({
				backendUrl,
				session,
			});
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to authenticate private account.");
		} finally {
			setIsAuthenticating(false);
		}
	}, [
	backendUrl,
	email,
	loadConnectors,
	password,
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
			await clearSessionRecord();
			setConnectorsIfUnchanged([]);
		}
	}, [clearSessionRecord, sessionRecord]);

	const handleDeleteAccount = useCallback(async () => {
		if (!sessionRecord) {
			return;
		}

		setIsDeletingAccount(true);
		setErrorMessage(null);
		try {
			await deletePrivateAccount({
				backendUrl: sessionRecord.backendUrl,
				getAccessToken: () => sessionRecord.session.accessToken,
			});
		} catch {
			// best effort — even if the server call fails, clear the local session
		} finally {
			await clearSessionRecord();
			setConnectorsIfUnchanged([]);
			setIsDeletingAccount(false);
		}
	}, [clearSessionRecord, sessionRecord]);

	const authenticateButtonLabel = useMemo(() => {
		if (isAuthenticating) {
			return "Working...";
		}

		return "Log in";
	}, [isAuthenticating]);
	const subscriptionState = (() => {
		if (subscriptionSnapshot.isSubscribed && shouldShowConnectorList) {
			return (
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
			);
		}

		if (!subscriptionSnapshot.isSubscribed) {
			return (
				<View style={styles.subscribeCard} testID="private-account-subscribe-cta">
					<Text style={styles.subscribeEyebrow}>Subscription required</Text>
					<Text style={styles.subscribeTitle}>Unlock private connectors on mobile</Text>
					<Text style={styles.supportText}>
						Subscribe to keep private sync active on this device and connect private servers.
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
			);
		}

		return null;
	})();

	return (
		<View style={styles.section}>
			<View style={styles.sectionHeader}>
				<View>
					<Text style={styles.sectionTitle}>Private Account</Text>
					{sessionRecord ? null : (
						<Text selectable style={styles.supportText}>
							Sign in to sync desktop and mobile.
						</Text>
					)}
				</View>
				{sessionRecord ? (
					<Pressable
						onPress={() => {
							void handleLogout();
						}}
						style={({ pressed }) => [
							styles.secondaryButton,
							pressed ? styles.secondaryButtonPressed : null,
						]}
						testID="private-account-logout"
					>
						<Text style={styles.secondaryLabel}>Logout</Text>
					</Pressable>
				) : null}
			</View>

			{sessionRecord ? (
				<View style={styles.formBody}>
					<Text selectable style={styles.summaryValue}>{sessionRecord.session.user.email}</Text>
					{subscriptionSnapshot.isSubscribed ? (
						<Text selectable style={styles.supportText}>
							{`Active - ${String(subscriptionSnapshot.daysRemaining)} days remaining`}
						</Text>
					) : null}

					{subscriptionState}
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

			{sessionRecord ? (
				<Pressable
					disabled={isDeletingAccount}
					onPress={() => {
						setIsDeleteConfirmVisible(true);
					}}
					style={({ pressed }) => [
						styles.dangerButton,
						pressed ? styles.dangerButtonPressed : null,
						isDeletingAccount ? styles.disabledButton : null,
					]}
					testID="private-account-delete"
				>
					<Text style={styles.dangerLabel}>{isDeletingAccount ? "Deleting..." : "Delete account"}</Text>
				</Pressable>
			) : null}

			<View style={styles.legalLinks}>
				<Pressable
					onPress={() => {
						void Linking.openURL(privacyPolicyUrl);
					}}
					testID="private-account-privacy-policy"
				>
					<Text style={styles.legalText}>Privacy Policy</Text>
				</Pressable>
				<Text style={styles.legalSeparator}>·</Text>
				<Pressable
					onPress={() => {
						void Linking.openURL(termsOfUseUrl);
					}}
					testID="private-account-terms-of-use"
				>
					<Text style={styles.legalText}>Terms of Use</Text>
				</Pressable>
			</View>

			{errorMessage ? (
				<View style={styles.statusBox}>
					<Text selectable style={styles.statusText}>{errorMessage}</Text>
				</View>
			) : null}

			<IosActionSheet
				actions={[
					{
						icon: "delete-forever",
						key: "confirm-delete-account",
						label: "Delete my account",
						onPress: () => {
							void handleDeleteAccount();
						},
						testID: "private-account-delete-confirm",
						tone: "destructive",
					},
				]}
				isVisible={isDeleteConfirmVisible}
				message="This will permanently delete your account, subscription, and all associated data. This action cannot be undone."
				onClose={() => {
					setIsDeleteConfirmVisible(false);
				}}
				testID="private-account-delete-sheet"
				title="Delete Account"
			/>
		</View>
	);
};

const styles = StyleSheet.create({
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
	dangerButton: {
		alignItems: "center",
		borderColor: "rgba(255,107,133,0.38)",
		borderRadius: 10,
		borderWidth: 1,
		height: 34,
		justifyContent: "center",
		paddingHorizontal: 12,
	},
	dangerButtonPressed: {
		backgroundColor: "rgba(255,107,133,0.12)",
	},
	dangerLabel: {
		color: "#FF8F98",
		fontSize: 13,
		fontWeight: "600",
	},
	legalLinks: {
		alignItems: "center",
		flexDirection: "row",
		gap: 6,
		justifyContent: "center",
		paddingTop: 4,
	},
	legalSeparator: {
		color: palette.muted,
		fontSize: 12,
	},
	legalText: {
		color: palette.muted,
		fontSize: 12,
		textDecorationLine: "underline",
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
