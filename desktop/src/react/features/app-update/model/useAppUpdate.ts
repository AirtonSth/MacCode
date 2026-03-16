import { useCallback, useEffect, useState } from "react";

export interface AppUpdateState {
	currentVersion: string;
	dismissed: boolean;
	hasUpdate: boolean;
	latestVersion: string;
	loading: boolean;
	releaseUrl: string;
}

interface UpdateInfo {
	currentVersion: string;
	hasUpdate: boolean;
	latestVersion: string;
	releaseUrl: string;
}

interface UseAppUpdateOptions {
	checkOnMount?: boolean;
	electrobunRpc: {
		request: Record<string, (...args: never[]) => Promise<unknown>>;
	} | null;
}

const INITIAL_STATE: AppUpdateState = {
	currentVersion: "",
	dismissed: false,
	hasUpdate: false,
	latestVersion: "",
	loading: false,
	releaseUrl: "",
};

export const useAppUpdate = ({ checkOnMount = true, electrobunRpc }: UseAppUpdateOptions) => {
	const [updateState, setUpdateState] = useState<AppUpdateState>(INITIAL_STATE);

	const check = useCallback(async () => {
		if (!electrobunRpc) {
			return;
		}

		const rpcCheckForUpdates = electrobunRpc.request.checkForUpdates as
			| (() => Promise<UpdateInfo>)
			| undefined;

		if (!rpcCheckForUpdates) {
			return;
		}

		setUpdateState((prev) => ({ ...prev, loading: true }));

		try {
			const info = await rpcCheckForUpdates();
			setUpdateState((prev) => ({
				...prev,
				currentVersion: info.currentVersion,
				hasUpdate: info.hasUpdate,
				latestVersion: info.latestVersion,
				loading: false,
				releaseUrl: info.releaseUrl,
			}));
		} catch {
			setUpdateState((prev) => ({ ...prev, loading: false }));
		}
	}, [electrobunRpc]);

	const dismiss = useCallback(() => {
		setUpdateState((prev) => ({ ...prev, dismissed: true }));
	}, []);

	const openRelease = useCallback(async () => {
		if (!electrobunRpc || !updateState.releaseUrl) {
			return;
		}

		const rpcOpenExternalUrl = electrobunRpc.request.openExternalUrl as
			| ((url: string) => Promise<void>)
			| undefined;

		if (rpcOpenExternalUrl) {
			await rpcOpenExternalUrl(updateState.releaseUrl);
		}
	}, [electrobunRpc, updateState.releaseUrl]);

	useEffect(() => {
		if (checkOnMount) {
			void check();
		}
	}, [check, checkOnMount]);

	return { ...updateState, check, dismiss, openRelease };
};
