/* eslint-disable import/no-unresolved, sonarjs/no-clear-text-protocols */
import { expect, test } from "bun:test";

import type { SavedConnection } from "@/shared/api/api-config-store";
import type { DiscoveredServer } from "@/shared/api/discovery-manager";

import { buildSavedConnectionItems } from "./settings-screen.model";

const makeServer = (overrides?: Partial<DiscoveredServer>): DiscoveredServer => ({
	authMode: "token_lan",
	baseUrl: "http://desktop.local:8835",
	capabilitiesVersion: "1",
	hostname: "Desktop Connector",
	lastSeenAt: "2026-03-14T10:00:00.000Z",
	port: 8835,
	serverId: "srv_1",
	version: "1.0.0",
	...overrides,
});

test("buildSavedConnectionItems hides saved local connections that are not online", () => {
	const savedConnections: SavedConnection[] = [
		{
			baseUrl: "http://offline.local:8835",
			kind: "local",
			lastConnectedAt: "2026-03-14T09:00:00.000Z",
			token: "token",
		},
	];

	const items = buildSavedConnectionItems({
		discoveredServers: [],
		privateConnectors: [],
		savedConnections,
		sessionBackendUrl: null,
	});

	expect(items).toEqual([]);
});

test("buildSavedConnectionItems keeps online saved local connections and dedupes discovery", () => {
	const savedConnections: SavedConnection[] = [
		{
			baseUrl: "http://desktop.local:8835",
			kind: "local",
			lastConnectedAt: "2026-03-14T09:00:00.000Z",
			token: "token",
		},
	];

	const items = buildSavedConnectionItems({
		discoveredServers: [makeServer()],
		privateConnectors: [],
		savedConnections,
		sessionBackendUrl: null,
	});

	expect(items).toHaveLength(1);
	expect(items[0]).toMatchObject({
		canDelete: true,
		kind: "saved-connection",
		title: "Desktop Connector",
	});
});

test("buildSavedConnectionItems matches saved local connections after baseUrl normalization", () => {
	const savedConnections: SavedConnection[] = [
		{
			baseUrl: "HTTP://Desktop.Local/",
			kind: "local",
			lastConnectedAt: "2026-03-14T09:00:00.000Z",
			token: "token",
		},
	];

	const items = buildSavedConnectionItems({
		discoveredServers: [makeServer()],
		privateConnectors: [],
		savedConnections,
		sessionBackendUrl: null,
	});

	expect(items).toHaveLength(1);
	expect(items[0]).toMatchObject({
		canDelete: true,
		kind: "saved-connection",
		title: "Desktop Connector",
	});
});

test("buildSavedConnectionItems only includes online private connectors", () => {
	const items = buildSavedConnectionItems({
		discoveredServers: [],
		privateConnectors: [
			{
				claimedAt: null,
				hostname: "online.local",
				id: "con_online",
				isOnline: true,
				lastSeenAt: "2026-03-14T11:00:00.000Z",
				name: "Online Connector",
				relayCapabilitiesVersion: null,
				relayVersion: null,
				status: "online",
			},
			{
				claimedAt: null,
				hostname: "offline.local",
				id: "con_offline",
				isOnline: false,
				lastSeenAt: "2026-03-14T10:00:00.000Z",
				name: "Offline Connector",
				relayCapabilitiesVersion: null,
				relayVersion: null,
				status: "offline",
			},
		],
		savedConnections: [],
		sessionBackendUrl: "https://private.remotecode.io:8787",
	});

	expect(items).toHaveLength(1);
	expect(items[0]).toMatchObject({
		kind: "private-connector",
		title: "Online Connector",
	});
});

test("buildSavedConnectionItems hides saved private connections from a different backend", () => {
	const items = buildSavedConnectionItems({
		discoveredServers: [],
		privateConnectors: [
			{
				claimedAt: null,
				hostname: "online.local",
				id: "con_online",
				isOnline: true,
				lastSeenAt: "2026-03-14T11:00:00.000Z",
				name: "Online Connector",
				relayCapabilitiesVersion: null,
				relayVersion: null,
				status: "online",
			},
		],
		savedConnections: [
			{
				backendUrl: "https://other.remotecode.dev",
				connectorId: "con_online",
				connectorName: "Saved Online Connector",
				kind: "private",
				lastConnectedAt: "2026-03-14T10:00:00.000Z",
			},
		],
		sessionBackendUrl: "https://private.remotecode.io:8787",
	});

	expect(items).toHaveLength(1);
	expect(items[0]).toMatchObject({
		kind: "private-connector",
		title: "Online Connector",
	});
});
