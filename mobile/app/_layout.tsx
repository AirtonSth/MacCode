import "react-native-reanimated";

import * as SplashScreen from "expo-splash-screen";

import { RootLayoutContent } from "@/navigation/root-layout-content";
import { ApiConfigProvider } from "@/shared/api/api-config-provider";
import { PrivateSessionProvider } from "@/shared/api/private-session-provider";

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
