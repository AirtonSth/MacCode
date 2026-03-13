import { useLocalSearchParams, useRouter } from "expo-router";
import { useEffect, useMemo, useRef, useState } from "react";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";

import { ApiConfigStore } from "@/shared/api/api-config-store";
import { usePrivateSession } from "@/shared/api/private-session-provider";
import { buildPrivateConnectUrlFromParams } from "@/shared/api/private-mobile-connect";
import { theme } from "@/shared/theme/tokens";
import { runConnectRouteFlow } from "./connect.model";

const normalizeParam = (value: string | string[] | undefined): string => {
	if (Array.isArray(value)) {
		return value[0]?.trim() ?? "";
	}

	return value?.trim() ?? "";
};

export default function ConnectRoute() {
	const params = useLocalSearchParams<{
		backendUrl?: string | string[];
		sessionId?: string | string[];
		token?: string | string[];
		url?: string | string[];
	}>();
	const router = useRouter();
	const attemptedRef = useRef<string | null>(null);
	const {
		activateConnector,
		clearPendingQrPayload,
		isLoaded,
		sessionRecord,
		setPendingQrPayload,
		setSessionRecord,
	} = usePrivateSession();
	const [errorMessage, setErrorMessage] = useState<string | null>(null);
	const [statusMessage, setStatusMessage] = useState("Verifying the QR link and preparing your private session.");

	const rawUrl = useMemo(() => {
		const rawUrl = normalizeParam(params.url);
		if (rawUrl) {
			return rawUrl;
		}

		return buildPrivateConnectUrlFromParams({
			backendUrl: normalizeParam(params.backendUrl),
			code: normalizeParam(params.token),
			sessionId: normalizeParam(params.sessionId),
		});
	}, [params.backendUrl, params.sessionId, params.token, params.url]);

	useEffect(() => {
		if (!isLoaded || !rawUrl || attemptedRef.current === rawUrl) {
			return undefined;
		}

		attemptedRef.current = rawUrl;
		let cancelled = false;

		void (async () => {
			const result = await runConnectRouteFlow({
				activateConnector,
				clearPendingQrPayload,
				onStatusMessage: setStatusMessage,
				rawUrl,
				saveSavedPrivateConnection: async (input) => {
					await ApiConfigStore.saveSavedConnection({
						backendUrl: input.backendUrl,
						connectorId: input.connectorId,
						connectorName: input.connectorName,
						kind: "private",
					});
				},
				sessionRecord,
				setPendingQrPayload,
				setSessionRecord,
			});
			if (cancelled) {
				return;
			}

			if (result.statusMessage) {
				setStatusMessage(result.statusMessage);
			}
			if (result.pathname === "/workspaces") {
				router.replace("/workspaces");
				return;
			}

			if (result.errorMessage) {
				setErrorMessage(result.errorMessage);
			}
			router.replace({
				params: result.privateConnectError
					? {
							privateConnectError: result.privateConnectError,
						}
					: undefined,
				pathname: "/settings",
			});
		})();

		return () => {
			cancelled = true;
		};
	}, [
		activateConnector,
		clearPendingQrPayload,
		isLoaded,
		rawUrl,
		router,
		sessionRecord,
		sessionRecord?.backendUrl,
		setPendingQrPayload,
		setSessionRecord,
	]);

	useEffect(() => {
		if (rawUrl || attemptedRef.current === "__missing__") {
			return;
		}

		attemptedRef.current = "__missing__";
		const message = "Invalid or expired private connection link.";
		setErrorMessage(message);
		router.replace({
			params: {
				privateConnectError: message,
			},
			pathname: "/settings",
		});
	}, [rawUrl, router]);

	return (
		<View style={styles.root}>
			{errorMessage ? (
				<>
					<Text style={styles.title}>Unable to Connect</Text>
					<Text style={styles.body}>{errorMessage}</Text>
					<Pressable
						onPress={() => {
							router.replace("/settings");
						}}
						style={({ pressed }) => [styles.button, pressed ? styles.buttonPressed : null]}
					>
						<Text style={styles.buttonLabel}>Open Settings</Text>
					</Pressable>
				</>
				) : (
					<>
						<ActivityIndicator color={theme.colors.accent} size="large" />
						<Text style={styles.title}>Connecting Desktop</Text>
						<Text style={styles.body}>{statusMessage}</Text>
					</>
				)}
			</View>
	);
}

const styles = StyleSheet.create({
	body: {
		color: theme.colors.textSecondary,
		fontSize: 15,
		lineHeight: 22,
		maxWidth: 280,
		textAlign: "center",
	},
	button: {
		alignItems: "center",
		backgroundColor: theme.colors.accent,
		borderRadius: 12,
		marginTop: 20,
		minWidth: 180,
		paddingHorizontal: 18,
		paddingVertical: 12,
	},
	buttonLabel: {
		color: theme.colors.background,
		fontSize: 14,
		fontWeight: "700",
	},
	buttonPressed: {
		opacity: 0.82,
	},
	root: {
		alignItems: "center",
		backgroundColor: theme.colors.background,
		flex: 1,
		gap: 16,
		justifyContent: "center",
		paddingHorizontal: 24,
	},
	title: {
		color: theme.colors.textPrimary,
		fontSize: 24,
		fontWeight: "700",
		textAlign: "center",
	},
});
