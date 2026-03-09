import {
	createPrivateClient,
	type PrivateConnectorDto,
	type PrivateSessionDto,
} from "@remotecode/contracts";

export const sortPrivateConnectors = (connectors: PrivateConnectorDto[]): PrivateConnectorDto[] =>
	Array.from(connectors).sort((left, right) => {
		if (left.status === right.status) {
			return (right.lastSeenAt ?? "").localeCompare(left.lastSeenAt ?? "");
		}

		return left.status === "online" ? -1 : 1;
	});

export const authenticatePrivateAccount = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
	mode: "login" | "register";
	password: string;
}): Promise<PrivateSessionDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	return input.mode === "login"
		? await client.login({
			email: input.email,
			password: input.password,
		})
		: await client.register({
			email: input.email,
			password: input.password,
		});
};

export const resolvePendingPrivateConnector = (input: {
	connectors: PrivateConnectorDto[];
	pendingConnectorId: string | null;
}): PrivateConnectorDto | null =>
	input.connectors.find((connector) => connector.id === input.pendingConnectorId) ?? null;

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
