import * as Linking from "expo-linking";
import * as SplashScreen from "expo-splash-screen";
import { Stack, useRouter } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";

import {
	exchangePrivateAuthCompletion,
	parsePrivateAuthCompletionInput,
} from "@/shared/api/private-auth-completion";
import { usePrivateSession } from "@/shared/api/private-session-provider";
import { queryClient } from "@/shared/api/query-client";
import { initializeThreadLiveActivityManager } from "@/shared/live-activity/thread-live-activity";
import { initializeLocalNotifications } from "@/shared/notifications/local-notifications";
import { ForegroundInsomniaMode } from "@/shared/runtime/foreground-insomnia-mode";
import { theme } from "@/shared/theme/tokens";
import { AnimatedLaunchSplash } from "@/shared/ui/animated-launch-splash";
import { QueryClientProvider } from "@tanstack/react-query";

export const RootLayoutContent = () => {
	const [isLaunchSplashVisible, setIsLaunchSplashVisible] = useState(true);
	const lastHandledPrivateUrlRef = useRef<string | null>(null);
	const router = useRouter();
	const { setSessionRecord } = usePrivateSession();

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
			}
		})();

		return true;
	}, [router, setSessionRecord]);

	const routePrivateUrl = useCallback((rawUrl: string | null) => {
		if (!rawUrl) {
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
		void (async () => {
			try {
				await SplashScreen.hideAsync();
			} catch {
				// Ignore native splash hide failures.
			}
		})();
	}, []);

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
