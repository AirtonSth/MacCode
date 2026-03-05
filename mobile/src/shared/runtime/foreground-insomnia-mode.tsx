import { usePathname } from "expo-router";
import { activateKeepAwakeAsync, deactivateKeepAwake } from "expo-keep-awake";
import { useEffect, useRef, useState } from "react";
import { AppState, Platform, type AppStateStatus } from "react-native";

import { useActiveThreadsQuery } from "../../features/threads/api/use-active-threads-query";
import { useApiConfig } from "../api/api-config-provider";

const INSOMNIA_KEEP_AWAKE_TAG = "remotecode.insomnia.foreground";

const isChatRoute = (pathname: string): boolean => pathname === "/chat";

export const ForegroundInsomniaMode = () => {
	const pathname = usePathname();
	const { isLoaded: isConfigLoaded } = useApiConfig();
	const [appState, setAppState] = useState<AppStateStatus>(AppState.currentState);
	const isForeground = appState === "active";
	const keepAwakeActiveRef = useRef(false);

	const activeThreadsQuery = useActiveThreadsQuery(
		Platform.OS === "ios" && isConfigLoaded && isForeground,
	);
	const activeThreadsCount = activeThreadsQuery.data?.length ?? 0;

	const shouldKeepAwake =
		Platform.OS === "ios" &&
		isForeground &&
		(isChatRoute(pathname) || activeThreadsCount > 0);

	useEffect(() => {
		const subscription = AppState.addEventListener("change", (nextState) => {
			setAppState(nextState);
		});

		return () => {
			subscription.remove();
		};
	}, []);

	useEffect(() => {
		if (Platform.OS !== "ios") {
			return;
		}

		if (shouldKeepAwake) {
			if (keepAwakeActiveRef.current) {
				return;
			}

			keepAwakeActiveRef.current = true;
			const activate = async () => {
				try {
					await activateKeepAwakeAsync(INSOMNIA_KEEP_AWAKE_TAG);
				} catch {
					keepAwakeActiveRef.current = false;
				}
			};
			void activate();
			return;
		}

		if (!keepAwakeActiveRef.current) {
			return;
		}

		keepAwakeActiveRef.current = false;
		const deactivate = async () => {
			try {
				await deactivateKeepAwake(INSOMNIA_KEEP_AWAKE_TAG);
			} catch {
				keepAwakeActiveRef.current = true;
			}
		};
		void deactivate();
	}, [shouldKeepAwake]);

	useEffect(() => {
		return () => {
			if (Platform.OS !== "ios" || !keepAwakeActiveRef.current) {
				return;
			}

			keepAwakeActiveRef.current = false;
			void deactivateKeepAwake(INSOMNIA_KEEP_AWAKE_TAG);
		};
	}, []);

	return null;
};
