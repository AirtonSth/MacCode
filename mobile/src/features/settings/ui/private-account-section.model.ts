import {
	createPrivateClient,
	type PrivateConnectorDto,
	type PrivateSessionDto,
} from "@remotecode/contracts";

import { ApiConfigStore } from "../../../shared/api/api-config-store";

const REMOTECODE_WEB_URL = "https://remotecode.io";

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

export const resolvePendingPrivateConnector = (input: {
	connectors: PrivateConnectorDto[];
	pendingConnectorId: string | null;
}): PrivateConnectorDto | null =>
	input.connectors.find((connector) => connector.id === input.pendingConnectorId) ?? null;

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
	resumePendingQrConnection: (connectors: PrivateConnectorDto[]) => Promise<void>;
}): Promise<void> => {
	try {
		const connectors = await input.loadConnectors();
		await input.resumePendingQrConnection(connectors);
	} catch (error) {
		input.onError(error instanceof Error ? error.message : "Unable to load private connectors.");
	}
};
