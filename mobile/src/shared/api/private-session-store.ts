import type { PrivateSessionDto } from "@remotecode/contracts";

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
	sessionRecord: PersistedPrivateSessionRecord | null;
}

const PRIVATE_STATE_KEY = "remotecode.private_session_state";

let secureStoreOverride: SecureStoreLike | null = null;
let secureStorePromise: Promise<SecureStoreLike> | null = null;

const loadSecureStore = async (): Promise<SecureStoreLike> => {
	const module = await import("expo-secure-store");
	return {
		deleteItemAsync: module.deleteItemAsync,
		getItemAsync: module.getItemAsync,
		setItemAsync: module.setItemAsync,
	};
};

const getSecureStore = async (): Promise<SecureStoreLike> => {
	if (secureStoreOverride) {
		return secureStoreOverride;
	}

	secureStorePromise ??= loadSecureStore();
	return await secureStorePromise;
};

const normalizeBackendUrl = (value: string): string => value.trim().replace(/\/+$/u, "");

const parsePrivateState = (raw: string | null): PersistedPrivateState => {
	if (!raw) {
		return {
			sessionRecord: null,
		};
	}

	try {
		const parsed = JSON.parse(raw) as Partial<PersistedPrivateState> | null;
		const sessionRecord = parsed?.sessionRecord;
		if (
			!sessionRecord
			|| typeof sessionRecord !== "object"
			|| typeof sessionRecord.backendUrl !== "string"
			|| !sessionRecord.session
		) {
			return {
				sessionRecord: null,
			};
		}

		return {
			sessionRecord: {
				backendUrl: normalizeBackendUrl(sessionRecord.backendUrl),
				session: sessionRecord.session,
			},
		};
	} catch {
		return {
			sessionRecord: null,
		};
	}
};

const writePrivateState = async (state: PersistedPrivateState): Promise<PersistedPrivateState> => {
	const secureStore = await getSecureStore();
	if (!state.sessionRecord) {
		await secureStore.deleteItemAsync(PRIVATE_STATE_KEY);
		return {
			sessionRecord: null,
		};
	}

	await secureStore.setItemAsync(PRIVATE_STATE_KEY, JSON.stringify(state));
	return state;
};

export const PrivateSessionStore = {
	async clearSessionRecord(): Promise<void> {
		await writePrivateState({
			sessionRecord: null,
		});
	},
	async read(): Promise<PersistedPrivateState> {
		const secureStore = await getSecureStore();
		return parsePrivateState(await secureStore.getItemAsync(PRIVATE_STATE_KEY));
	},
	async saveSessionRecord(input: PersistedPrivateSessionRecord): Promise<PersistedPrivateSessionRecord> {
		const normalized = {
			backendUrl: normalizeBackendUrl(input.backendUrl),
			session: input.session,
		};
		await writePrivateState({
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
	secureStorePromise = null;
};
