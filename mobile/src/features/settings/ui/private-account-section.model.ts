import {
	createPrivateClient,
	PrivateApiError,
	type PrivateConnectorDto,
	type PrivateSessionDto,
	type PrivateSubscriptionSnapshotDto,
} from "@remotecode/contracts";

import type { PersistedPrivateSessionRecord } from "../../../shared/api/private-session-store";
import { ApiConfigStore } from "../../../shared/api/api-config-store";
import { getNativeSubscriptionManagementUrl, type RevenueCatPlatform } from "../../../shared/billing/revenuecat.model";

const REMOTECODE_WEB_URL = "https://remotecode.io";
const REMOTECODE_PRIVACY_POLICY_URL = `${REMOTECODE_WEB_URL}/privacy`;
const REMOTECODE_TERMS_OF_USE_URL = `${REMOTECODE_WEB_URL}/terms`;

const trimBaseUrl = (value: string): string => value.trim().replace(/\/+$/u, "");

export const buildNativeManageSubscriptionUrl = (platform: RevenueCatPlatform): string =>
	getNativeSubscriptionManagementUrl(platform);

export const buildPrivacyPolicyUrl = (): string => REMOTECODE_PRIVACY_POLICY_URL;

export const buildTermsOfUseUrl = (): string => REMOTECODE_TERMS_OF_USE_URL;

export const deletePrivateAccount = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
}): Promise<void> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.backendUrl,
		getAccessToken: input.getAccessToken,
	});
	await client.deleteAccount();
};

export const getPrivateSubscriptionSnapshot = (
	session: PrivateSessionDto | null | undefined,
): {
	daysRemaining: number;
	isSubscribed: boolean;
} => ({
	daysRemaining: session?.user.daysRemaining ?? session?.user.daysRemaing ?? 0,
	isSubscribed: Boolean(session?.user.subscribed),
});

export const sortPrivateConnectors = (connectors: PrivateConnectorDto[]): PrivateConnectorDto[] =>
	Array.from(connectors).sort((left, right) => {
		if (left.status === right.status) {
			return (right.lastSeenAt ?? "").localeCompare(left.lastSeenAt ?? "");
		}

		return left.status === "online" ? -1 : 1;
	});

export const loginPrivateAccount = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
	password: string;
}): Promise<PrivateSessionDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	return await client.login({
		email: input.email,
		password: input.password,
	});
};

export const registerPrivateAccount = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
	password: string;
}): Promise<PrivateSessionDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	return await client.register({
		email: input.email,
		password: input.password,
	});
};

export const requestPrivatePasswordReset = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
}): Promise<void> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	await client.requestPasswordReset({
		email: input.email,
	});
};

export const syncPrivateRevenueCatSubscriptionStatus = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
}): Promise<PrivateSubscriptionSnapshotDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.backendUrl,
		getAccessToken: input.getAccessToken,
	});

	const response = await client.syncRevenueCatSubscription();
	return response.subscription;
};

type PrivateClientWithMeOnly = Pick<ReturnType<typeof createPrivateClient>, "me">;

export const refreshPrivateAccountSessionRecord = async (input: {
	createClient?: (config: Parameters<typeof createPrivateClient>[0]) => PrivateClientWithMeOnly;
	refreshSession?: () => Promise<PrivateSessionDto | null>;
	sessionRecord: PersistedPrivateSessionRecord | null;
}): Promise<PersistedPrivateSessionRecord | null> => {
	if (!input.sessionRecord) {
		return null;
	}

	const sessionRecord = input.sessionRecord;
	const createBackendClient = (accessToken: string) => (input.createClient ?? createPrivateClient)({
		baseUrl: sessionRecord.backendUrl,
		getAccessToken: () => accessToken,
	});

	try {
		const response = await createBackendClient(sessionRecord.session.accessToken).me();
		return {
			backendUrl: sessionRecord.backendUrl,
			session: {
				...sessionRecord.session,
				user: response.user,
			},
		};
	} catch (error) {
		if (!(error instanceof PrivateApiError) || error.status !== 401) {
			throw error;
		}

		if (!input.refreshSession) {
			return null;
		}

		const refreshedSession = await input.refreshSession();
		if (!refreshedSession) {
			return null;
		}

		const refreshedResponse = await createBackendClient(refreshedSession.accessToken).me();
		return {
			backendUrl: input.sessionRecord.backendUrl,
			session: {
				...refreshedSession,
				user: refreshedResponse.user,
			},
		};
	}
};

export const persistSavedPrivateConnection = async (input: {
	backendUrl: string;
	connector: Pick<PrivateConnectorDto, "id" | "name">;
	saveSavedConnection?: typeof ApiConfigStore.saveSavedConnection;
}): Promise<void> => {
	await (input.saveSavedConnection ?? ApiConfigStore.saveSavedConnection)({
		backendUrl: trimBaseUrl(input.backendUrl),
		connectorId: input.connector.id,
		connectorName: input.connector.name,
		kind: "private",
	});
};

export const loadPrivateConnectorsSafely = async (input: {
	loadConnectors: () => Promise<PrivateConnectorDto[]>;
	onError: (message: string) => void;
}): Promise<void> => {
	try {
		await input.loadConnectors();
	} catch (error) {
		input.onError(error instanceof Error ? error.message : "Unable to load private connectors.");
	}
};
