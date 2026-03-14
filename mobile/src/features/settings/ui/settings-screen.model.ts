import type { PrivateConnectorDto } from "@remotecode/contracts";

import type {
	LocalSavedConnection,
	PrivateSavedConnection,
	SavedConnection,
} from "@/shared/api/api-config-store";
import type { DiscoveredServer } from "@/shared/api/discovery-manager";

interface SavedConnectionRowItem<TConnection extends SavedConnection = SavedConnection> {
	kind: "saved-connection";
	canDelete: boolean;
	connection: TConnection;
	key: string;
	subtitle: string;
	title: string;
}

export type SavedConnectionListItem =
	| SavedConnectionRowItem
	| {
		kind: "discovered-server";
		canDelete: false;
		key: string;
		server: DiscoveredServer;
		subtitle: string;
		title: string;
	}
	| {
		kind: "private-connector";
		canDelete: false;
		connector: PrivateConnectorDto;
		key: string;
		subtitle: string;
		title: string;
	};

type LocalSavedConnectionRowItem = SavedConnectionRowItem<LocalSavedConnection>;
type PrivateSavedConnectionRowItem = SavedConnectionRowItem<PrivateSavedConnection>;

const PRIVATE_CONNECTOR_ONLINE = "online";
const DEFAULT_SERVER_PORT = "8835";

const toHost = (value: string): string => {
	const trimmed = value.trim().toLowerCase();
	if (trimmed.length === 0) {
		return "";
	}

	const withoutProtocol = trimmed.includes("://") ? trimmed.split("://", 2)[1] : trimmed;
	const withoutPath = withoutProtocol.split(/[/?#]/u, 1)[0] ?? "";
	if (withoutPath.length === 0) {
		return "";
	}

	const authSplitIndex = withoutPath.lastIndexOf("@");
	const hostPort = authSplitIndex !== -1 ? withoutPath.slice(authSplitIndex + 1) : withoutPath;
	if (hostPort.startsWith("[")) {
		const closingIndex = hostPort.indexOf("]");
		if (closingIndex > 1) {
			return hostPort.slice(1, closingIndex).trim();
		}
		return "";
	}

	return hostPort.split(":", 1)[0].trim();
};

const toSavedConnectionKey = (connection: SavedConnection): string =>
	connection.kind === "private"
		? `private:${connection.backendUrl}:${connection.connectorId}`
		: `local:${connection.baseUrl}`;

const getSavedConnectionTitle = (connection: SavedConnection): string =>
	connection.kind === "private"
		? connection.connectorName
		: toHost(connection.baseUrl) || connection.baseUrl;

const normalizeLocalBaseUrl = (value: string): string => {
	const trimmed = value.trim();
	if (trimmed.length === 0) {
		return "";
	}

	const withProtocol = trimmed.includes("://") ? trimmed : `http://${trimmed}`;
	const [rawProtocol = "", rawAddress = ""] = withProtocol.split("://", 2);
	const protocol = rawProtocol.trim().toLowerCase() === "https" ? "https" : "http";
	const authority = (rawAddress.split(/[/?#]/u, 1)[0] ?? "").trim();
	if (authority.length === 0) {
		return "";
	}

	const authSplitIndex = authority.lastIndexOf("@");
	const hostPort = authSplitIndex !== -1 ? authority.slice(authSplitIndex + 1) : authority;
	if (hostPort.length === 0) {
		return "";
	}

	if (hostPort.startsWith("[")) {
		const closingIndex = hostPort.indexOf("]");
		if (closingIndex <= 1) {
			return "";
		}

		const host = hostPort.slice(1, closingIndex).trim().toLowerCase();
		if (host.length === 0) {
			return "";
		}

		const suffix = hostPort.slice(closingIndex + 1).trim();
		const candidatePort = suffix.startsWith(":") ? suffix.slice(1).trim() : "";
		const port = candidatePort.length > 0 ? candidatePort : DEFAULT_SERVER_PORT;
		if (!/^\d+$/u.test(port)) {
			return "";
		}

		return `${protocol}://[${host}]:${port}`;
	}

	const [host = "", rawPort = ""] = hostPort.split(":", 2);
	const normalizedHost = host.trim().toLowerCase();
	if (normalizedHost.length === 0) {
		return "";
	}

	const port = rawPort.trim().length > 0 ? rawPort.trim() : DEFAULT_SERVER_PORT;
	if (!/^\d+$/u.test(port)) {
		return "";
	}

	return `${protocol}://${normalizedHost}:${port}`;
};

const isPrivateConnectorConnectable = (connector: PrivateConnectorDto): boolean =>
	connector.isOnline && connector.status === PRIVATE_CONNECTOR_ONLINE;

export const buildSavedConnectionItems = (input: {
	discoveredServers: DiscoveredServer[];
	privateConnectors: PrivateConnectorDto[];
	savedConnections: SavedConnection[];
	sessionBackendUrl: string | null;
}): SavedConnectionListItem[] => {
	const discoveredServerByBaseUrl = new Map<string, DiscoveredServer>();
	for (const server of input.discoveredServers) {
		const normalizedBaseUrl = normalizeLocalBaseUrl(server.baseUrl);
		if (normalizedBaseUrl.length > 0 && !discoveredServerByBaseUrl.has(normalizedBaseUrl)) {
			discoveredServerByBaseUrl.set(normalizedBaseUrl, server);
		}
	}

	const localSavedItems: LocalSavedConnectionRowItem[] = input.savedConnections
		.filter((item) => item.kind === "local")
		.filter((connection) => discoveredServerByBaseUrl.has(normalizeLocalBaseUrl(connection.baseUrl)))
		.map((connection) => {
			const matchedServer = discoveredServerByBaseUrl.get(normalizeLocalBaseUrl(connection.baseUrl));
			return {
				canDelete: true,
				connection,
				key: toSavedConnectionKey(connection),
				kind: "saved-connection",
				subtitle: matchedServer?.hostname || toHost(connection.baseUrl) || connection.baseUrl,
				title: matchedServer?.hostname || getSavedConnectionTitle(connection),
			};
		});

	const readyPrivateConnectors = input.privateConnectors.filter((connector) => {
		if (!input.sessionBackendUrl) {
			return false;
		}

		if (connector.id.length === 0) {
			return false;
		}

		return isPrivateConnectorConnectable(connector);
	});
	const readyPrivateConnectorIds = new Set(readyPrivateConnectors.map((connector) => connector.id));

	const privateSavedIds = new Set<string>();
	const privateSavedItems: PrivateSavedConnectionRowItem[] = input.savedConnections
		.filter((item) => item.kind === "private")
		.filter((item) => item.backendUrl === input.sessionBackendUrl)
		.filter((item) => readyPrivateConnectorIds.has(item.connectorId))
		.map((item) => {
			privateSavedIds.add(item.connectorId);
			return {
				canDelete: true,
				connection: item,
				key: toSavedConnectionKey(item),
				kind: "saved-connection",
				subtitle: `Private server · ${toHost(item.backendUrl)}`,
				title: getSavedConnectionTitle(item),
			};
		});

	const privateConnectorItems = readyPrivateConnectors
		.filter((connector) => !privateSavedIds.has(connector.id))
		.map<SavedConnectionListItem>((connector) => ({
			canDelete: false,
			connector,
			kind: "private-connector",
			key: `private:${input.sessionBackendUrl ?? ""}:${connector.id}`,
			subtitle: `${connector.hostname ?? "No host"} · ${connector.status}`,
			title: connector.name,
		}));

	const savedLocalBaseUrls = new Set(
		localSavedItems.map((entry) => normalizeLocalBaseUrl(entry.connection.baseUrl)).filter((value) => value.length > 0),
	);
	const discoveredItems = input.discoveredServers
		.filter((server) => !savedLocalBaseUrls.has(normalizeLocalBaseUrl(server.baseUrl)))
		.map<SavedConnectionListItem>((server) => ({
			canDelete: false,
			key: server.serverId,
			kind: "discovered-server",
			server,
			subtitle: toHost(server.baseUrl) || server.baseUrl,
			title: server.hostname || toHost(server.baseUrl) || server.baseUrl,
		}));

	return [...localSavedItems, ...privateSavedItems, ...discoveredItems, ...privateConnectorItems];
};
