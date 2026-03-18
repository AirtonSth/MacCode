import { NativeModules, Platform } from "react-native";

import type { LiveActivitySharedSnapshot } from "./live-activity-shared-snapshot";

interface LiveActivitySharedSnapshotNativeModule {
	getGlobalLiveActivitySnapshot?: () => Promise<string | null>;
	setGlobalLiveActivitySnapshot?: (snapshotJson: string | null) => Promise<void>;
}

const nativeModule = NativeModules
	.RemoteCodeSharedSnapshotModule as LiveActivitySharedSnapshotNativeModule | undefined;

export const persistGlobalLiveActivitySharedSnapshot = async (
	snapshot: LiveActivitySharedSnapshot | null,
): Promise<void> => {
	if (Platform.OS !== "ios" || !nativeModule?.setGlobalLiveActivitySnapshot) {
		return;
	}

	await nativeModule.setGlobalLiveActivitySnapshot(
		snapshot ? JSON.stringify(snapshot) : null,
	);
};

export const readPersistedGlobalLiveActivitySharedSnapshot = async (): Promise<LiveActivitySharedSnapshot | null> => {
	if (Platform.OS !== "ios" || !nativeModule?.getGlobalLiveActivitySnapshot) {
		return null;
	}

	const rawSnapshot = await nativeModule.getGlobalLiveActivitySnapshot();
	if (!rawSnapshot) {
		return null;
	}

	try {
		return JSON.parse(rawSnapshot) as LiveActivitySharedSnapshot;
	} catch {
		return null;
	}
};
