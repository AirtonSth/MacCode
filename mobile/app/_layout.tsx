import "react-native-reanimated";

import { QueryClientProvider } from "@tanstack/react-query";
import * as SplashScreen from "expo-splash-screen";
import { Stack } from "expo-router";
import { useEffect } from "react";

import { ApiConfigProvider } from "@/shared/api/api-config-provider";
import { queryClient } from "@/shared/api/query-client";
import { registerThreadLiveActivityBackgroundTask } from "@/shared/live-activity/thread-live-activity-background";
import { initializeThreadLiveActivityManager } from "@/shared/live-activity/thread-live-activity";
import { initializeLocalNotifications } from "@/shared/notifications/local-notifications";
import { theme } from "@/shared/theme/tokens";

export {
	ErrorBoundary,
} from "expo-router";

SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
	useEffect(() => {
		void SplashScreen.hideAsync();
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

			try {
				await registerThreadLiveActivityBackgroundTask();
			} catch {
				// Ignore startup background-task initialization failures.
			}
		})();
	}, []);

	return (
		<ApiConfigProvider>
			<QueryClientProvider client={queryClient}>
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
					<Stack.Screen name="chat" options={{ headerShown: false }} />
					<Stack.Screen name="settings" options={{ headerShown: false }} />
				</Stack>
			</QueryClientProvider>
		</ApiConfigProvider>
	);
}
