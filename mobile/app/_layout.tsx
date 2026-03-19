import "react-native-reanimated";

import * as SplashScreen from "expo-splash-screen";
import { useEffect, useState } from "react";

import { RootLayoutContent } from "@/navigation/root-layout-content";
import { ApiConfigProvider } from "@/shared/api/api-config-provider";
import { ApiConfigStore, type ApiConfig } from "@/shared/api/api-config-store";
import { PrivateSessionProvider } from "@/shared/api/private-session-provider";
import { PrivateSessionStore, type PersistedPrivateSessionRecord } from "@/shared/api/private-session-store";

export {
	ErrorBoundary,
} from "expo-router";

SplashScreen.preventAutoHideAsync();

interface BootData {
	apiConfig: ApiConfig;
	sessionRecord: PersistedPrivateSessionRecord | null;
}

export default function RootLayout() {
	const [bootData, setBootData] = useState<BootData | null>(null);

	useEffect(() => {
		void (async () => {
			const [apiConfig, sessionState] = await Promise.all([
				ApiConfigStore.read(),
				PrivateSessionStore.read(),
			]);
			setBootData({
				apiConfig,
				sessionRecord: sessionState.sessionRecord,
			});
		})();
	}, []);

	if (!bootData) {
		return null;
	}

	return (
		<ApiConfigProvider initialConfig={bootData.apiConfig}>
			<PrivateSessionProvider initialSessionRecord={bootData.sessionRecord}>
				<RootLayoutContent />
			</PrivateSessionProvider>
		</ApiConfigProvider>
	);
}
