import type { RevenueCatPlatform } from "../billing/revenuecat.model";

interface SecureStoreLike {
	deleteItemAsync: (key: string) => Promise<void>;
	getItemAsync: (key: string) => Promise<string | null>;
	setItemAsync: (key: string, value: string) => Promise<void>;
}

export interface PersistedPrivateSignupIntentRecord {
	backendUrl: string;
	email: string;
	platform: RevenueCatPlatform;
	signupIntentId: string;
}

const PRIVATE_SIGNUP_INTENT_KEY = "remotecode.private_signup_intent";

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
const normalizeEmail = (value: string): string => value.trim().toLowerCase();
const normalizeSignupIntentId = (value: string): string => value.trim();

const parseRecord = (raw: string | null): PersistedPrivateSignupIntentRecord | null => {
	if (!raw) {
		return null;
	}

	try {
		const parsed = JSON.parse(raw) as Partial<PersistedPrivateSignupIntentRecord> | null;
		if (
			!parsed
			|| typeof parsed.backendUrl !== "string"
			|| typeof parsed.email !== "string"
			|| typeof parsed.platform !== "string"
			|| typeof parsed.signupIntentId !== "string"
		) {
			return null;
		}

		const backendUrl = normalizeBackendUrl(parsed.backendUrl);
		const email = normalizeEmail(parsed.email);
		const signupIntentId = normalizeSignupIntentId(parsed.signupIntentId);
		if (!backendUrl || !email || !signupIntentId || (parsed.platform !== "ios" && parsed.platform !== "android")) {
			return null;
		}

		return {
			backendUrl,
			email,
			platform: parsed.platform,
			signupIntentId,
		};
	} catch {
		return null;
	}
};

const normalizeRecord = (
	input: PersistedPrivateSignupIntentRecord,
): PersistedPrivateSignupIntentRecord => ({
	backendUrl: normalizeBackendUrl(input.backendUrl),
	email: normalizeEmail(input.email),
	platform: input.platform,
	signupIntentId: normalizeSignupIntentId(input.signupIntentId),
});

export const PrivateSignupIntentStore = {
	async clear(): Promise<void> {
		const secureStore = await getSecureStore();
		await secureStore.deleteItemAsync(PRIVATE_SIGNUP_INTENT_KEY);
	},
	async read(): Promise<PersistedPrivateSignupIntentRecord | null> {
		const secureStore = await getSecureStore();
		return parseRecord(await secureStore.getItemAsync(PRIVATE_SIGNUP_INTENT_KEY));
	},
	async save(input: PersistedPrivateSignupIntentRecord): Promise<PersistedPrivateSignupIntentRecord> {
		const secureStore = await getSecureStore();
		const normalized = normalizeRecord(input);
		await secureStore.setItemAsync(PRIVATE_SIGNUP_INTENT_KEY, JSON.stringify(normalized));
		return normalized;
	},
};

export const setPrivateSignupIntentSecureStoreForTests = (adapter: SecureStoreLike) => {
	secureStoreOverride = adapter;
};

export const resetPrivateSignupIntentSecureStoreForTests = () => {
	secureStoreOverride = null;
	secureStorePromise = null;
};
