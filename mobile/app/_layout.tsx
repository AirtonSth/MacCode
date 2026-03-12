import "react-native-reanimated";

import * as SplashScreen from "expo-splash-screen";

import { ApiConfigProvider } from "@/shared/api/api-config-provider";
import { PrivateSessionProvider } from "@/shared/api/private-session-provider";

import { RootLayoutContent } from "./root-layout-content";

export {
	ErrorBoundary,
} from "expo-router";

SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
	return (
		<ApiConfigProvider>
			<PrivateSessionProvider>
				<RootLayoutContent />
			</PrivateSessionProvider>
		</ApiConfigProvider>
	);
}
