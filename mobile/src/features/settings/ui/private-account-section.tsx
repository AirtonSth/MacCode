import {
	createPrivateClient,
	type PrivateConnectorDto,
	type PrivateSessionDto,
} from "@remotecode/contracts";
import * as Linking from "expo-linking";
import * as WebBrowser from "expo-web-browser";
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
import { revenueCatPurchasesClient } from "../../../shared/billing/revenuecat";
import {
	formatPrivateSubscriptionPriceLabel,
	isRevenueCatConfigured,
} from "../../../shared/billing/revenuecat.model";
import { IosActionSheet } from "../../../shared/ui/ios-action-sheet";
import {
	buildNativeManageSubscriptionUrl,
	buildPrivacyPolicyUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	getPrivateSubscriptionSnapshot,
	loadPrivateConnectorsSafely,
	loginPrivateAccount,
	persistSavedPrivateConnection,
	refreshPrivateAccountSessionRecord,
	registerPrivateAccount,
	requestPrivatePasswordReset,
	sortPrivateConnectors,
	syncPrivateRevenueCatSubscriptionStatus,
} from "./private-account-section.model";
import {
	didRevenueCatUnlockPrivateAccess,
	purchasePrivateSubscription,
	restorePrivateSubscriptionPurchases,
} from "./private-subscription.model";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	soft: "rgba(255,255,255,0.05)",
	text: "#F1F4FA",
};

const DEFAULT_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787";

type AuthMode = "login" | "register";

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
			leftConnector.id === rightConnector?.id
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
	const [authMode, setAuthMode] = useState<AuthMode>("login");
	const [confirmPassword, setConfirmPassword] = useState("");
	const [connectors, setConnectors] = useState<PrivateConnectorDto[]>([]);
	const [email, setEmail] = useState("");
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [noticeMessage, setNoticeMessage] = useState<string | null>(null);
	const [isDeletingAccount, setIsDeletingAccount] = useState(false);
	const [isDeleteConfirmVisible, setIsDeleteConfirmVisible] = useState(false);
	const [isLoadingConnectors, setIsLoadingConnectors] = useState(false);
	const [isOptionsSheetVisible, setIsOptionsSheetVisible] = useState(false);
	const [isPurchasingSubscription, setIsPurchasingSubscription] = useState(false);
	const [isRestoringSubscription, setIsRestoringSubscription] = useState(false);
	const [isSendingPasswordReset, setIsSendingPasswordReset] = useState(false);
	const [isSubmittingAuth, setIsSubmittingAuth] = useState(false);
	const [password, setPassword] = useState("");
	const subscriptionSnapshot = useMemo(
		() => getPrivateSubscriptionSnapshot(sessionRecord?.session),
		[sessionRecord?.session],
	);
	const mobilePlatform = Platform.OS === "android" ? "android" : "ios";
	const revenueCatReady = useMemo(() => isRevenueCatConfigured(mobilePlatform), [mobilePlatform]);
	const manageSubscriptionUrl = useMemo(
		() => buildNativeManageSubscriptionUrl(mobilePlatform),
		[mobilePlatform],
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

		if (revenueCatReady) {
			try {
				await syncPrivateRevenueCatSubscriptionStatus({
					backendUrl: record.backendUrl,
					getAccessToken: () => record.session.accessToken,
				});
			} catch {
				// Keep the last known subscription state if the RevenueCat sync fails.
			}
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
		revenueCatReady,
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
		setNoticeMessage(null);
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

	useEffect(() => {
		if (!sessionRecord) {
			return;
		}

		void (async () => {
			try {
				await revenueCatPurchasesClient.ensureConfigured(sessionRecord.session.user.id);
			} catch {
				// Avoid surfacing silent RevenueCat configuration failures on mount.
			}
		})();
	}, [sessionRecord]);

	const handleAuthenticate = useCallback(async () => {
		const trimmedEmail = email.trim();
		const trimmedPassword = password.trim();
		if (!trimmedEmail || !trimmedPassword) {
			setErrorMessage("Email and password are required.");
			return;
		}

		if (authMode === "register" && trimmedPassword !== confirmPassword.trim()) {
			setErrorMessage("Passwords do not match.");
			return;
		}

		setIsSubmittingAuth(true);
		setErrorMessage(null);
		setNoticeMessage(null);
		try {
			const session = authMode === "register"
				? await registerPrivateAccount({
					baseUrl: backendUrl,
					email: trimmedEmail,
					password: trimmedPassword,
				})
				: await loginPrivateAccount({
					baseUrl: backendUrl,
					email: trimmedEmail,
					password: trimmedPassword,
				});
			const nextRecord = {
				backendUrl,
				session,
			};
			await setSessionRecord(nextRecord);
			await loadConnectors(nextRecord);
			setConfirmPassword("");
			setPassword("");
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to authenticate private account.");
		} finally {
			setIsSubmittingAuth(false);
		}
	}, [
		authMode,
		backendUrl,
		confirmPassword,
		email,
		loadConnectors,
		password,
		setSessionRecord,
	]);

	const handleForgotPassword = useCallback(async () => {
		const trimmedEmail = email.trim();
		if (!trimmedEmail) {
			setErrorMessage("Enter your account email first.");
			return;
		}

		setIsSendingPasswordReset(true);
		setErrorMessage(null);
		setNoticeMessage(null);
		try {
			await requestPrivatePasswordReset({
				baseUrl: backendUrl,
				email: trimmedEmail,
			});
			setNoticeMessage(`Password reset instructions were sent to ${trimmedEmail}.`);
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to send a password reset email.");
		} finally {
			setIsSendingPasswordReset(false);
		}
	}, [backendUrl, email]);

	const handleLogout = useCallback(async () => {
		setErrorMessage(null);
		setNoticeMessage(null);
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
		setNoticeMessage(null);
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

	const handlePurchaseSubscription = useCallback(async () => {
		if (!sessionRecord) {
			return;
		}

		setIsPurchasingSubscription(true);
		setErrorMessage(null);
		setNoticeMessage(null);
		try {
			const result = await purchasePrivateSubscription({
				backendUrl: sessionRecord.backendUrl,
				getAccessToken: () => sessionRecord.session.accessToken,
				purchasesClient: revenueCatPurchasesClient,
				userId: sessionRecord.session.user.id,
			});
			await loadConnectors(sessionRecord);
			if (!result.subscription.subscribed && !didRevenueCatUnlockPrivateAccess(result.customerInfo)) {
				setNoticeMessage("Purchase completed. Tap Restore purchases if access is not active yet.");
				return;
			}

			setNoticeMessage("Subscription activated on this device.");
		} catch (error) {
			if (revenueCatPurchasesClient.isPurchaseCancelled(error)) {
				return;
			}

			setErrorMessage(error instanceof Error ? error.message : "Unable to start the subscription purchase.");
		} finally {
			setIsPurchasingSubscription(false);
		}
	}, [loadConnectors, sessionRecord]);

	const handleRestorePurchases = useCallback(async () => {
		if (!sessionRecord) {
			return;
		}

		setIsRestoringSubscription(true);
		setErrorMessage(null);
		setNoticeMessage(null);
		try {
			const result = await restorePrivateSubscriptionPurchases({
				backendUrl: sessionRecord.backendUrl,
				getAccessToken: () => sessionRecord.session.accessToken,
				purchasesClient: revenueCatPurchasesClient,
				userId: sessionRecord.session.user.id,
			});
			await loadConnectors(sessionRecord);
			if (!result.subscription.subscribed && !didRevenueCatUnlockPrivateAccess(result.customerInfo)) {
				setNoticeMessage("No active App Store subscription was restored for this account.");
				return;
			}

			setNoticeMessage("Purchases restored successfully.");
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to restore purchases.");
		} finally {
			setIsRestoringSubscription(false);
		}
	}, [loadConnectors, sessionRecord]);

	const openInAppBrowser = useCallback(async (url: string) => {
		await WebBrowser.openBrowserAsync(url);
	}, []);

	const authenticateButtonLabel = useMemo(() => {
		if (isSubmittingAuth) {
			return authMode === "register" ? "Creating account..." : "Signing in...";
		}

		return authMode === "register" ? "Create account" : "Log in";
	}, [authMode, isSubmittingAuth]);

	const subscribeButtonLabel = useMemo(() => {
		if (isPurchasingSubscription) {
			return "Starting purchase...";
		}

		return revenueCatReady
			? `Subscribe for ${formatPrivateSubscriptionPriceLabel()}`
			: "Finish RevenueCat setup";
	}, [isPurchasingSubscription, revenueCatReady]);

	const restoreButtonLabel = useMemo(() => {
		if (isRestoringSubscription) {
			return "Restoring...";
		}

		return "Restore purchases";
	}, [isRestoringSubscription]);

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
					<Text style={styles.subscribeEyebrow}>In-app purchase required</Text>
					<Text style={styles.subscribeTitle}>Unlock private connectors on mobile</Text>
					<Text style={styles.subscribePrice}>{formatPrivateSubscriptionPriceLabel()}</Text>
					<Text style={styles.supportText}>
						Buy the subscription in-app or restore an existing App Store purchase for this account.
					</Text>
					<Pressable
						disabled={!sessionRecord || isPurchasingSubscription || isRestoringSubscription || !revenueCatReady}
						onPress={() => {
							void handlePurchaseSubscription();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							!sessionRecord || isPurchasingSubscription || isRestoringSubscription || !revenueCatReady
								? styles.disabledButton
								: null,
						]}
						testID="private-account-subscribe-button"
					>
						<Text style={styles.primaryLabel}>{subscribeButtonLabel}</Text>
					</Pressable>
					<View style={styles.inlineActions}>
						<Pressable
							disabled={!sessionRecord || isPurchasingSubscription || isRestoringSubscription || !revenueCatReady}
							onPress={() => {
								void handleRestorePurchases();
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
								!sessionRecord || isPurchasingSubscription || isRestoringSubscription || !revenueCatReady
									? styles.disabledButton
									: null,
							]}
							testID="private-account-restore-purchases"
						>
							<Text style={styles.secondaryLabel}>{restoreButtonLabel}</Text>
						</Pressable>
						<Pressable
							onPress={() => {
								void Linking.openURL(manageSubscriptionUrl);
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
							testID="private-account-manage-subscription"
						>
							<Text style={styles.secondaryLabel}>Open subscriptions</Text>
						</Pressable>
					</View>
					{!revenueCatReady ? (
						<Text style={styles.supportText}>
							RevenueCat is still using placeholder keys. Finish the setup and rebuild the app before testing purchases.
						</Text>
					) : null}
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
							Sign in or create an account to sync desktop and mobile.
						</Text>
					)}
				</View>
				{sessionRecord ? (
					<Pressable
						onPress={() => {
							setIsOptionsSheetVisible(true);
						}}
						style={({ pressed }) => [
							styles.optionsButton,
							pressed ? styles.secondaryButtonPressed : null,
						]}
						testID="private-account-options"
					>
						<Text style={styles.optionsLabel}>⋯</Text>
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
					<View style={styles.segmentedControl}>
						<Pressable
							onPress={() => {
								setAuthMode("login");
								setErrorMessage(null);
								setNoticeMessage(null);
							}}
							style={({ pressed }) => [
								styles.segmentedButton,
								authMode === "login" ? styles.segmentedButtonActive : null,
								pressed ? styles.segmentedButtonPressed : null,
							]}
							testID="private-account-mode-login"
						>
							<Text style={authMode === "login" ? styles.segmentedLabelActive : styles.segmentedLabel}>Log in</Text>
						</Pressable>
						<Pressable
							onPress={() => {
								setAuthMode("register");
								setErrorMessage(null);
								setNoticeMessage(null);
							}}
							style={({ pressed }) => [
								styles.segmentedButton,
								authMode === "register" ? styles.segmentedButtonActive : null,
								pressed ? styles.segmentedButtonPressed : null,
							]}
							testID="private-account-mode-register"
						>
							<Text style={authMode === "register" ? styles.segmentedLabelActive : styles.segmentedLabel}>Create account</Text>
						</Pressable>
					</View>
					<TextInput
						autoCapitalize="none"
						keyboardType="email-address"
						onChangeText={(value) => {
							setEmail(value);
							setErrorMessage(null);
							setNoticeMessage(null);
						}}
						placeholder="dev@example.com"
						placeholderTextColor={palette.muted}
						style={styles.input}
						testID="private-account-email"
						value={email}
					/>
					<TextInput
						onChangeText={(value) => {
							setPassword(value);
							setErrorMessage(null);
							setNoticeMessage(null);
						}}
						placeholder="Password"
						placeholderTextColor={palette.muted}
						secureTextEntry
						style={styles.input}
						testID="private-account-password"
						value={password}
					/>
					{authMode === "register" ? (
						<TextInput
							onChangeText={(value) => {
								setConfirmPassword(value);
								setErrorMessage(null);
								setNoticeMessage(null);
							}}
							placeholder="Confirm password"
							placeholderTextColor={palette.muted}
							secureTextEntry
							style={styles.input}
							testID="private-account-password-confirm"
							value={confirmPassword}
						/>
					) : null}
					<Pressable
						disabled={
							isSubmittingAuth
							|| backendUrl.trim().length === 0
							|| email.trim().length === 0
							|| password.trim().length === 0
							|| (authMode === "register" && confirmPassword.trim().length === 0)
						}
						onPress={() => {
							void handleAuthenticate();
						}}
						style={({ pressed }) => [
							styles.primaryButton,
							pressed ? styles.primaryButtonPressed : null,
							isSubmittingAuth ? styles.disabledButton : null,
						]}
						testID="private-account-authenticate"
					>
						<Text style={styles.primaryLabel}>{authenticateButtonLabel}</Text>
					</Pressable>
					<View style={styles.inlineActions}>
						<Pressable
							disabled={isSendingPasswordReset || email.trim().length === 0}
							onPress={() => {
								void handleForgotPassword();
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
								isSendingPasswordReset || email.trim().length === 0 ? styles.disabledButton : null,
							]}
							testID="private-account-forgot-password"
						>
							<Text style={styles.secondaryLabel}>
								{isSendingPasswordReset ? "Sending..." : "Send reset link"}
							</Text>
						</Pressable>
						<Pressable
							onPress={() => {
								setAuthMode(authMode === "login" ? "register" : "login");
								setConfirmPassword("");
								setErrorMessage(null);
								setNoticeMessage(null);
							}}
							style={({ pressed }) => [
								styles.secondaryButton,
								styles.inlineButton,
								pressed ? styles.secondaryButtonPressed : null,
							]}
							testID="private-account-switch-auth-mode"
						>
							<Text style={styles.secondaryLabel}>
								{authMode === "login" ? "Create account" : "Use login"}
							</Text>
						</Pressable>
					</View>
				</View>
			)}

			<View style={styles.legalLinks}>
				<Pressable
					onPress={() => {
						void openInAppBrowser(privacyPolicyUrl);
					}}
					testID="private-account-privacy-policy"
				>
					<Text style={styles.legalText}>Privacy Policy</Text>
				</Pressable>
				<Text style={styles.legalSeparator}>·</Text>
				<Pressable
					onPress={() => {
						void openInAppBrowser(termsOfUseUrl);
					}}
					testID="private-account-terms-of-use"
				>
					<Text style={styles.legalText}>Terms of Use</Text>
				</Pressable>
			</View>

			{noticeMessage ? (
				<View style={styles.noticeBox}>
					<Text selectable style={styles.noticeText}>{noticeMessage}</Text>
				</View>
			) : null}
			{errorMessage ? (
				<View style={styles.statusBox}>
					<Text selectable style={styles.statusText}>{errorMessage}</Text>
				</View>
			) : null}

			<IosActionSheet
				actions={[
					{
						icon: "logout",
						key: "logout",
						label: "Logout",
						onPress: () => {
							void handleLogout();
						},
						testID: "private-account-logout",
					},
					{
						icon: "delete-forever",
						key: "delete-account",
						label: isDeletingAccount ? "Deleting..." : "Delete account",
						onPress: () => {
							setIsDeleteConfirmVisible(true);
						},
						testID: "private-account-delete",
						tone: "destructive",
					},
				]}
				isVisible={isOptionsSheetVisible}
				onClose={() => {
					setIsOptionsSheetVisible(false);
				}}
				testID="private-account-options-sheet"
				title="Account"
			/>

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
	noticeBox: {
		backgroundColor: "rgba(99,200,255,0.12)",
		borderColor: "rgba(99,200,255,0.32)",
		borderRadius: 12,
		borderWidth: 1,
		padding: 12,
	},
	noticeText: {
		color: palette.text,
		fontSize: 13,
		lineHeight: 19,
	},
	optionsButton: {
		alignItems: "center",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		height: 34,
		justifyContent: "center",
		width: 34,
	},
	optionsLabel: {
		color: palette.text,
		fontSize: 18,
		fontWeight: "700",
		marginTop: -2,
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
	segmentedButton: {
		alignItems: "center",
		borderRadius: 10,
		flex: 1,
		height: 34,
		justifyContent: "center",
	},
	segmentedButtonActive: {
		backgroundColor: palette.soft,
		borderColor: palette.border,
		borderWidth: 1,
	},
	segmentedButtonPressed: {
		opacity: 0.85,
	},
	segmentedControl: {
		backgroundColor: "rgba(255,255,255,0.03)",
		borderColor: palette.border,
		borderRadius: 12,
		borderWidth: 1,
		flexDirection: "row",
		padding: 4,
	},
	segmentedLabel: {
		color: palette.muted,
		fontSize: 13,
		fontWeight: "600",
	},
	segmentedLabelActive: {
		color: palette.text,
		fontSize: 13,
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
	subscribePrice: {
		color: palette.text,
		fontSize: 22,
		fontWeight: "700",
	},
	subscribeTitle: {
		color: palette.text,
		fontSize: 17,
		fontWeight: "700",
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
