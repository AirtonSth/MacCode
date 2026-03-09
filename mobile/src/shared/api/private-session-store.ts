import * as SecureStore from "expo-secure-store";

import type {
	DesktopMobileConnectQrPayloadDto,
	PrivateSessionDto,
} from "@remotecode/contracts";

interface SecureStoreLike {
	deleteItemAsync: (key: string) => Promise<void>;
	getItemAsync: (key: string) => Promise<string | null>;
	setItemAsync: (key: string, value: string) => Promise<void>;
}

export interface PersistedPrivateSessionRecord {
	backendUrl: string;
	session: PrivateSessionDto;
}

interface PersistedPrivateState {
	pendingQrPayload: DesktopMobileConnectQrPayloadDto | null;
	sessionRecord: PersistedPrivateSessionRecord | null;
}

const PRIVATE_STATE_KEY = "remotecode.private_session_state";

let secureStoreOverride: SecureStoreLike | null = null;

const getSecureStore = (): SecureStoreLike => {
	if (secureStoreOverride) {
		return secureStoreOverride;
	}

	return SecureStore;
};

const normalizeBackendUrl = (value: string): string => value.trim().replace(/\/+$/u, "");

const normalizePendingQrPayload = (
	payload: DesktopMobileConnectQrPayloadDto | null | undefined,
): DesktopMobileConnectQrPayloadDto | null => {
	if (!payload) {
		return null;
	}

	return {
		...payload,
		backendUrl: normalizeBackendUrl(payload.backendUrl),
	};
};

const parsePrivateState = (raw: string | null): PersistedPrivateState => {
	if (!raw) {
		return {
			pendingQrPayload: null,
			sessionRecord: null,
		};
	}

	try {
		const parsed = JSON.parse(raw) as Partial<PersistedPrivateState> | null;
		const sessionRecord = parsed?.sessionRecord;
		const pendingQrPayload = normalizePendingQrPayload(parsed?.pendingQrPayload as DesktopMobileConnectQrPayloadDto | null);
		if (
			!sessionRecord
			|| typeof sessionRecord !== "object"
			|| typeof sessionRecord.backendUrl !== "string"
			|| !sessionRecord.session
		) {
			return {
				pendingQrPayload,
				sessionRecord: null,
			};
		}

			return {
				pendingQrPayload,
				sessionRecord: {
					backendUrl: normalizeBackendUrl(sessionRecord.backendUrl),
					session: sessionRecord.session,
				},
			};
	} catch {
		return {
			pendingQrPayload: null,
			sessionRecord: null,
		};
	}
};

const writePrivateState = async (state: PersistedPrivateState): Promise<PersistedPrivateState> => {
	if (!state.sessionRecord && !state.pendingQrPayload) {
		await getSecureStore().deleteItemAsync(PRIVATE_STATE_KEY);
		return {
			pendingQrPayload: null,
			sessionRecord: null,
		};
	}

	await getSecureStore().setItemAsync(PRIVATE_STATE_KEY, JSON.stringify(state));
	return state;
};

export const PrivateSessionStore = {
	async clearPendingQrPayload(): Promise<void> {
		const current = parsePrivateState(await getSecureStore().getItemAsync(PRIVATE_STATE_KEY));
		await writePrivateState({
			...current,
			pendingQrPayload: null,
		});
	},
	async clearSessionRecord(): Promise<void> {
		const current = parsePrivateState(await getSecureStore().getItemAsync(PRIVATE_STATE_KEY));
		await writePrivateState({
			...current,
			sessionRecord: null,
		});
	},
	async read(): Promise<PersistedPrivateState> {
		return parsePrivateState(await getSecureStore().getItemAsync(PRIVATE_STATE_KEY));
	},
	async savePendingQrPayload(payload: DesktopMobileConnectQrPayloadDto): Promise<DesktopMobileConnectQrPayloadDto> {
		const current = parsePrivateState(await getSecureStore().getItemAsync(PRIVATE_STATE_KEY));
		const normalized = normalizePendingQrPayload(payload);
		await writePrivateState({
			...current,
			pendingQrPayload: normalized,
		});
		return normalized!;
	},
	async saveSessionRecord(input: PersistedPrivateSessionRecord): Promise<PersistedPrivateSessionRecord> {
		const current = parsePrivateState(await getSecureStore().getItemAsync(PRIVATE_STATE_KEY));
		const normalized = {
			backendUrl: normalizeBackendUrl(input.backendUrl),
			session: input.session,
		};
		await writePrivateState({
			...current,
			sessionRecord: normalized,
		});
		return normalized;
	},
};

export const setPrivateSessionSecureStoreForTests = (adapter: SecureStoreLike) => {
	secureStoreOverride = adapter;
};

export const resetPrivateSessionSecureStoreForTests = () => {
	secureStoreOverride = null;
};
