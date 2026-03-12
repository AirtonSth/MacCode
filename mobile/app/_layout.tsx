import "react-native-reanimated";

import { QueryClientProvider } from "@tanstack/react-query";
import * as Linking from "expo-linking";
import * as SplashScreen from "expo-splash-screen";
import { Stack, usePathname, useRouter } from "expo-router";
import { useCallback, useEffect, useRef, useState } from "react";

import { ApiConfigProvider } from "@/shared/api/api-config-provider";
import {
	exchangePrivateAuthCompletion,
	parsePrivateAuthCompletionInput,
} from "@/shared/api/private-auth-completion";
import { parsePrivateConnectInput } from "@/shared/api/private-mobile-connect";
import { PrivateSessionProvider, usePrivateSession } from "@/shared/api/private-session-provider";
import { queryClient } from "@/shared/api/query-client";
import { initializeThreadLiveActivityManager } from "@/shared/live-activity/thread-live-activity";
import { initializeLocalNotifications } from "@/shared/notifications/local-notifications";
import { ForegroundInsomniaMode } from "@/shared/runtime/foreground-insomnia-mode";
import { theme } from "@/shared/theme/tokens";
import { AnimatedLaunchSplash } from "@/shared/ui/animated-launch-splash";

export {
	ErrorBoundary,
} from "expo-router";

SplashScreen.preventAutoHideAsync();

const RootLayoutContent = () => {
	const [isLaunchSplashVisible, setIsLaunchSplashVisible] = useState(true);
	const lastHandledPrivateUrlRef = useRef<string | null>(null);
	const pathname = usePathname();
	const router = useRouter();
	const { pendingQrPayload, setSessionRecord } = usePrivateSession();

	const routePrivateAuthCompletionUrl = useCallback((rawUrl: string | null): boolean => {
		if (!rawUrl) {
			return false;
		}

		let completion: ReturnType<typeof parsePrivateAuthCompletionInput>;
		try {
			completion = parsePrivateAuthCompletionInput(rawUrl);
		} catch {
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
				router.replace(pendingQrPayload ? "/settings" : "/workspaces");
			} catch (error) {
				if (lastHandledPrivateUrlRef.current === rawUrl) {
					lastHandledPrivateUrlRef.current = null;
				}
				router.replace({
					params: {
						privateConnectError: error instanceof Error ? error.message : "Unable to finish sign-in.",
					},
					pathname: "/settings" as never,
				});
			}
		})();

		return true;
	}, [pendingQrPayload, router, setSessionRecord]);

	const routePrivateConnectUrl = useCallback((rawUrl: string | null) => {
		if (!rawUrl) {
			return;
		}

		if (routePrivateAuthCompletionUrl(rawUrl)) {
			return;
		}

		try {
			parsePrivateConnectInput(rawUrl);
		} catch {
			return;
		}

		if (lastHandledPrivateUrlRef.current === rawUrl && pathname === "/connect") {
			return;
		}

		lastHandledPrivateUrlRef.current = rawUrl;
		router.replace({
			params: {
				url: rawUrl,
			},
			pathname: "/connect" as never,
		});
	}, [pathname, routePrivateAuthCompletionUrl, router]);

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
					routePrivateConnectUrl(initialUrl);
				}
			} catch {
				// Ignore malformed startup URLs.
			}
		})();

		const subscription = Linking.addEventListener("url", (event) => {
			routePrivateConnectUrl(event.url);
		});

		return () => {
			isActive = false;
			subscription.remove();
		};
	}, [routePrivateConnectUrl]);

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
				<Stack.Screen name="connect" options={{ headerShown: false }} />
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

export default function RootLayout() {
	return (
		<ApiConfigProvider>
			<PrivateSessionProvider>
				<RootLayoutContent />
			</PrivateSessionProvider>
		</ApiConfigProvider>
	);
}
