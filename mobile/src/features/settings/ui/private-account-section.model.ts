import { createPrivateClient, PrivateApiError ,type  PrivateConnectorDto,type  PrivateSessionDto } from "@remotecode/contracts";
import type { PersistedPrivateSessionRecord } from "../../../shared/api/private-session-store";

import { ApiConfigStore } from "../../../shared/api/api-config-store";

const REMOTECODE_WEB_URL = "https://remotecode.io";
const REMOTECODE_PRIVACY_POLICY_URL = `${REMOTECODE_WEB_URL}/privacy`;
const REMOTECODE_TERMS_OF_USE_URL = `${REMOTECODE_WEB_URL}/terms`;

const trimBaseUrl = (value: string): string => value.trim().replace(/\/+$/u, "");
const buildRemoteCodeWebUrl = (path: string, params: Record<string, string>): string => {
	const searchParams = new URLSearchParams();
	for (const [key, value] of Object.entries(params)) {
		searchParams.set(key, value);
	}

	return `${REMOTECODE_WEB_URL}${path}?${searchParams.toString()}`;
};

export const buildPrivateRegisterUrl = (input: {
	backendUrl: string;
	email?: string | null;
	platform: "android" | "ios";
}): string => {
	return buildRemoteCodeWebUrl("/register", {
		backendUrl: trimBaseUrl(input.backendUrl),
		...(input.email?.trim() ? { email: input.email.trim() } : {}),
		platform: input.platform,
		returnUrl: "remotecode://auth/complete",
		target: "mobile",
	});
};

export const buildPrivateForgotPasswordUrl = (input: {
	backendUrl: string;
	email?: string | null;
}): string => {
	return buildRemoteCodeWebUrl("/forgot-password", {
		backendUrl: trimBaseUrl(input.backendUrl),
		...(input.email?.trim() ? { email: input.email.trim() } : {}),
	});
};

export const buildPrivateManageSubscriptionUrl = (): string =>
	`${REMOTECODE_WEB_URL}/app`;

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

export const getPrivateSubscriptionSnapshot = (session: PrivateSessionDto | null | undefined) => ({
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
