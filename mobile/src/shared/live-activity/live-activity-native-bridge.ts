import { NativeEventEmitter, NativeModules, Platform } from "react-native";

import type { ThreadLiveActivityProps } from "./thread-live-activity.types";

export interface NativeLiveActivityInfo {
	activityId: string | null;
	pushToken: string | null;
}

interface NativeLiveActivityPushTokenEvent {
	activityId?: string | null;
	pushToken?: string | null;
}

interface NativePushToStartTokenEvent {
	pushToStartToken?: string | null;
}

interface RemoteCodeLiveActivityNativeModule {
	addListener?: (eventName: string) => void;
	endLiveActivity?: (payloadJson: string | null) => Promise<void>;
	getCurrentLiveActivityInfo?: () => Promise<string | null>;
	getPushToStartToken?: () => Promise<string | null>;
	removeListeners?: (count: number) => void;
	startLiveActivity?: (payloadJson: string, deepLink: string) => Promise<string | null>;
	updateLiveActivity?: (payloadJson: string) => Promise<string | null>;
}

const nativeModule = NativeModules
	.RemoteCodeLiveActivityBridge as RemoteCodeLiveActivityNativeModule | undefined;

let nativeEventEmitter: NativeEventEmitter | null = null;

const isBridgeAvailable = (): boolean =>
	Platform.OS === "ios"
	&& Boolean(nativeModule?.startLiveActivity)
	&& Boolean(nativeModule?.updateLiveActivity)
	&& Boolean(nativeModule?.getCurrentLiveActivityInfo);

const parseNativeInfo = (rawValue: string | null): NativeLiveActivityInfo | null => {
	if (!rawValue) {
		return null;
	}

	try {
		const parsed = JSON.parse(rawValue) as {
			activityId?: string | null;
			pushToken?: string | null;
		};
		return {
			activityId: parsed.activityId?.trim() || null,
			pushToken: parsed.pushToken?.trim() || null,
		};
	} catch {
		return null;
	}
};

const getNativeEventEmitter = (): NativeEventEmitter | null => {
	if (
		!isBridgeAvailable()
		|| !nativeModule?.addListener
		|| !nativeModule.removeListeners
	) {
		return null;
	}

	nativeEventEmitter ||= new NativeEventEmitter(
		nativeModule as never,
	);
	return nativeEventEmitter;
};

export const isNativeLiveActivityBridgeAvailable = (): boolean => isBridgeAvailable();

export const getCurrentNativeLiveActivityInfo = async (): Promise<NativeLiveActivityInfo | null> => {
	if (!isBridgeAvailable() || !nativeModule?.getCurrentLiveActivityInfo) {
		return null;
	}

	return parseNativeInfo(await nativeModule.getCurrentLiveActivityInfo());
};

export const startNativeLiveActivity = async (
	props: ThreadLiveActivityProps,
	deepLink: string,
): Promise<NativeLiveActivityInfo | null> => {
	if (!isBridgeAvailable() || !nativeModule?.startLiveActivity) {
		return null;
	}

	return parseNativeInfo(await nativeModule.startLiveActivity(JSON.stringify(props), deepLink));
};

export const updateNativeLiveActivity = async (
	props: ThreadLiveActivityProps,
): Promise<NativeLiveActivityInfo | null> => {
	if (!isBridgeAvailable() || !nativeModule?.updateLiveActivity) {
		return null;
	}

	return parseNativeInfo(await nativeModule.updateLiveActivity(JSON.stringify(props)));
};

export const endNativeLiveActivity = async (
	props: ThreadLiveActivityProps | null,
): Promise<void> => {
	if (!isBridgeAvailable() || !nativeModule?.endLiveActivity) {
		return;
	}

	await nativeModule.endLiveActivity(props ? JSON.stringify(props) : null);
};

export const getNativePushToStartToken = async (): Promise<string | null> => {
	if (!isBridgeAvailable() || !nativeModule?.getPushToStartToken) {
		return null;
	}

	const token = await nativeModule.getPushToStartToken();
	return token?.trim() || null;
};

export const subscribeNativeLiveActivityPushToken = (
	listener: (event: { activityId: string | null; pushToken: string }) => void,
): (() => void) => {
	const eventEmitter = getNativeEventEmitter();
	if (!eventEmitter) {
		return () => undefined;
	}

	const subscription = eventEmitter.addListener(
		"RemoteCodeLiveActivityPushToken",
		(event: NativeLiveActivityPushTokenEvent) => {
			const pushToken = event.pushToken?.trim() ?? "";
			if (pushToken.length === 0) {
				return;
			}

			listener({
				activityId: event.activityId?.trim() || null,
				pushToken,
			});
		},
	);

	return () => {
		subscription.remove();
	};
};

export const subscribeNativePushToStartToken = (
	listener: (token: string) => void,
): (() => void) => {
	const eventEmitter = getNativeEventEmitter();
	if (!eventEmitter) {
		return () => undefined;
	}

	const subscription = eventEmitter.addListener(
		"RemoteCodePushToStartToken",
		(event: NativePushToStartTokenEvent) => {
			const pushToStartToken = event.pushToStartToken?.trim() ?? "";
			if (pushToStartToken.length === 0) {
				return;
			}

			listener(pushToStartToken);
		},
	);

	return () => {
		subscription.remove();
	};
};
