/* eslint-disable @typescript-eslint/no-unsafe-call, @typescript-eslint/no-unsafe-member-access */
import * as Linking from "expo-linking";
import * as SplashScreen from "expo-splash-screen";
import { Stack, useRouter } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, StyleSheet, View } from "react-native";

import {
	exchangePrivateAuthCompletion,
	parsePrivateAuthCompletionInput,
} from "@/shared/api/private-auth-completion";
import { useApiConfig } from "@/shared/api/api-config-provider";
import { usePrivateSession } from "@/shared/api/private-session-provider";
import { queryClient } from "@/shared/api/query-client";
import {
	dismissTerminalLiveActivity,
	initializeThreadLiveActivityManager,
} from "@/shared/live-activity/thread-live-activity";
import { initializeLocalNotifications } from "@/shared/notifications/local-notifications";
import { ForegroundInsomniaMode } from "@/shared/runtime/foreground-insomnia-mode";
import { theme } from "@/shared/theme/tokens";
import { AnimatedLaunchSplash } from "@/shared/ui/animated-launch-splash";
import { QueryClientProvider } from "@tanstack/react-query";

export const RootLayoutContent = () => {
	const [isLaunchSplashVisible, setIsLaunchSplashVisible] = useState(true);
	const [isProcessingDeepLink, setIsProcessingDeepLink] = useState(false);
	const lastHandledPrivateUrlRef = useRef<string | null>(null);
	const router = useRouter();
	const { isLoaded: isConfigLoaded } = useApiConfig();
	const { isLoaded: isSessionLoaded, setSessionRecord } = usePrivateSession();

	const routePrivateAuthCompletionUrl = useCallback((rawUrl: string | null): boolean => {
		if (!rawUrl) {
			return false;
		}

		const completion = (() => {
			try {
				return parsePrivateAuthCompletionInput(rawUrl);
			} catch {
				return null;
			}
		})();
		if (!completion) {
			return false;
		}

		if (lastHandledPrivateUrlRef.current === rawUrl) {
			return true;
		}

		lastHandledPrivateUrlRef.current = rawUrl;
		setIsProcessingDeepLink(true);
		void (async () => {
			try {
				const sessionRecord = await exchangePrivateAuthCompletion({
					completion,
				});
				await setSessionRecord(sessionRecord);
				router.replace("/workspaces");
			} catch (error) {
				router.replace({
					params: {
						privateConnectError: error instanceof Error ? error.message : "Unable to finish sign-in.",
					},
					pathname: "/settings" as never,
				});
			} finally {
				setIsProcessingDeepLink(false);
			}
		})();

		return true;
	}, [router, setSessionRecord]);

	const routePrivateUrl = useCallback((rawUrl: string | null) => {
		if (!rawUrl) {
			return;
		}

		if (rawUrl.includes("://active-threads")) {
			void dismissTerminalLiveActivity();
			return;
		}

		if (lastHandledPrivateUrlRef.current === rawUrl) {
			return;
		}

		if (routePrivateAuthCompletionUrl(rawUrl)) {
			lastHandledPrivateUrlRef.current = rawUrl;
		}
	}, [routePrivateAuthCompletionUrl]);

	useEffect(() => {
		if (!isConfigLoaded || !isSessionLoaded) {
			return;
		}

		void (async () => {
			try {
				await SplashScreen.hideAsync();
			} catch {
				// Ignore native splash hide failures.
			}
		})();
	}, [isConfigLoaded, isSessionLoaded]);

	useEffect(() => {
		void (async () => {
			try {
				await initializeLocalNotifications();
			} catch {
				// Ignore startup notification initialization failures.
			}

			try {
				await initializeThreadLiveActivityManager();
			} catch {
				// Ignore startup live-activity initialization failures.
			}
		})();
	}, []);

	useEffect(() => {
		let isActive = true;
		void (async () => {
			try {
				const initialUrl = await Linking.getInitialURL();
				if (isActive) {
					routePrivateUrl(initialUrl);
				}
			} catch {
				// Ignore malformed startup URLs.
			}
		})();

		const subscription = Linking.addEventListener("url", (event) => {
			routePrivateUrl(event.url);
		});

		return () => {
			isActive = false;
			subscription.remove();
		};
	}, [routePrivateUrl]);

	return (
		<QueryClientProvider client={queryClient}>
			<ForegroundInsomniaMode />
			<Stack
				screenOptions={{
					contentStyle: {
						backgroundColor: theme.colors.background,
					},
					headerStyle: {
						backgroundColor: theme.colors.panelBackground,
					},
					headerTintColor: theme.colors.textPrimary,
				}}
			>
				<Stack.Screen name="index" options={{ headerShown: false }} />
				<Stack.Screen name="workspaces" options={{ headerShown: false }} />
				<Stack.Screen name="threads" options={{ headerShown: false }} />
				<Stack.Screen name="active-threads" options={{ headerShown: false }} />
				<Stack.Screen name="chat" options={{ headerShown: false }} />
				<Stack.Screen name="settings" options={{ headerShown: false }} />
			</Stack>
			{isProcessingDeepLink ? (
				<View style={deepLinkStyles.overlay} testID="deep-link-loading-overlay">
					<ActivityIndicator color="#63C8FF" size="large" />
				</View>
			) : null}
			{isLaunchSplashVisible ? (
				<AnimatedLaunchSplash
					onFinish={() => {
						setIsLaunchSplashVisible(false);
					}}
				/>
			) : null}
		</QueryClientProvider>
	);
};

const deepLinkStyles = StyleSheet.create({
	overlay: {
		...StyleSheet.absoluteFill,
		alignItems: "center",
		backgroundColor: "rgba(13,15,20,0.85)",
		justifyContent: "center",
		zIndex: 900,
	},
});
