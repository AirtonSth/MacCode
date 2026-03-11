import { hostname as readHostname } from "node:os";

import {
	createPrivateClient,
	type DesktopMobileConnectQrPayloadDto,
	type PrivateAccountStateDto,
	type PrivateConnectorDto,
	type PrivateSessionDto,
	PrivateApiError,
} from "@remotecode/contracts";

import type { ServerApp } from "../../app";
import { RelayConnectorClient } from "./relay-connector.client";
import type {
	PersistedPrivateConnector,
	PrivateAccountAuthInput,
	PrivateAccountStateSnapshot,
} from "./private-account.model";
import { PrivateAccountRepository } from "./private-account.repository";

interface PrivateAccountServiceOptions {
	backendUrl: string;
	clock?: () => Date;
	connectorName?: string;
	heartbeatIntervalMs?: number;
	localServerToken: string;
	mobileConnectRefreshIntervalMs?: number;
	reconnectDelayMs?: number;
}

interface MobileConnectQrLink {
	connectorId: string;
	expiresAt: string;
	generatedAtMs: number;
	linkUrl: string;
}

const DEFAULT_MOBILE_CONNECT_REFRESH_INTERVAL_MS = 5_000;

const PRIVATE_ACCOUNT_ERROR_MESSAGES: Record<string, string> = {
	missing_private_refresh_token: "Your session has expired. Please sign in again.",
	private_connector_token_missing: "Desktop pairing could not be completed. Please try again.",
	private_local_app_unavailable: "The local desktop service is unavailable. Please restart the app.",
	private_relay_connect_failed: "The desktop relay could not connect. Please try again.",
	private_relay_socket_error: "The desktop relay connection failed. Please try again.",
	private_state_refresh_failed: "We couldn't refresh your private account state. Please try again.",
};

const toPrivateAccountErrorMessage = (error: unknown, fallbackCode: string): string => {
	const message = error instanceof Error ? error.message : fallbackCode;
	if (PRIVATE_ACCOUNT_ERROR_MESSAGES[message]) {
		return PRIVATE_ACCOUNT_ERROR_MESSAGES[message];
	}

	return message.includes("_") ? "Something went wrong. Please try again." : message;
};

export class PrivateAccountService {
	private connector: PersistedPrivateConnector | null;
	private connectorDto: PrivateConnectorDto | null = null;
	private connectorRelayState: PrivateAccountStateDto["connectorRelayState"] = "idle";
	private errorMessage: string | null = null;
	private localApp: ServerApp | null = null;
	private localServerBaseUrl: string | null = null;
	private mobileConnectLink: MobileConnectQrLink | null = null;
	private reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
	private relayClient: RelayConnectorClient;
	private session: PrivateSessionDto | null;

	public constructor(
		private readonly repository: PrivateAccountRepository,
		private readonly options: PrivateAccountServiceOptions,
	) {
		this.session = this.repository.readSession();
		this.connector = this.repository.readConnector();
		this.relayClient = new RelayConnectorClient({
			heartbeatIntervalMs: options.heartbeatIntervalMs,
			localRequestHandler: async (input) => await this.handleLocalRequest(input),
			localServerToken: options.localServerToken,
			onError: (message) => {
				this.errorMessage = toPrivateAccountErrorMessage(new Error(message), message);
			},
			onStateChange: (state) => {
				this.connectorRelayState = state;
				if (state === "disconnected" && this.session && this.connector) {
					this.scheduleReconnect();
				}
			},
		});
	}

	public async attachRuntime(input: { app: ServerApp; baseUrl: string }): Promise<void> {
		this.localApp = input.app;
		this.localServerBaseUrl = input.baseUrl.replace(/\/+$/u, "");
		await this.resume();
	}

	public async getState(): Promise<PrivateAccountStateDto> {
		if (this.session && this.connector) {
			try {
				const connectors = await this.withPrivateAuth(async (client) => await client.listConnectors());
				this.connectorDto = connectors.connectors.find((item) => item.id === this.connector?.connectorId) ?? null;
				await this.ensureMobileConnectLink();
			} catch (error) {
				this.errorMessage = toPrivateAccountErrorMessage(error, "private_state_refresh_failed");
			}
		} else {
			this.connectorDto = null;
			this.mobileConnectLink = null;
		}

		const snapshot = this.snapshot();
		return {
			authenticated: Boolean(snapshot.user),
			connector: snapshot.connector,
			connectorRelayState: snapshot.connectorRelayState,
			errorMessage: snapshot.errorMessage,
			qrPayload: snapshot.qrPayload,
			user: snapshot.user,
		};
	}

	public async login(input: PrivateAccountAuthInput): Promise<PrivateAccountStateDto> {
		const client = createPrivateClient({
			baseUrl: this.options.backendUrl,
		});
		this.session = await client.login(input);
		this.repository.saveSession(this.session);
		this.errorMessage = null;
		await this.ensureConnector(true);
		return await this.getState();
	}

	public async logout(): Promise<PrivateAccountStateDto> {
		if (this.session?.refreshToken) {
			try {
				const client = createPrivateClient({
					baseUrl: this.options.backendUrl,
					getAccessToken: () => this.session?.accessToken ?? null,
				});
				await client.logout({ refreshToken: this.session.refreshToken });
			} catch {
				// Best effort logout
			}
		}

		this.clearPersistedState();
		return await this.getState();
	}

	public async register(input: PrivateAccountAuthInput): Promise<PrivateAccountStateDto> {
		const client = createPrivateClient({
			baseUrl: this.options.backendUrl,
		});
		this.session = await client.register(input);
		this.repository.saveSession(this.session);
		this.errorMessage = null;
		await this.ensureConnector(true);
		return await this.getState();
	}

	public async resume(): Promise<void> {
		if (!this.session || !this.connector || !this.localServerBaseUrl || !this.localApp) {
			return;
		}

		await this.ensureConnector(false);
	}

	private clearPersistedState(): void {
		this.clearReconnect();
		this.relayClient.stop();
		this.connector = null;
		this.connectorDto = null;
		this.connectorRelayState = "idle";
		this.errorMessage = null;
		this.mobileConnectLink = null;
		this.session = null;
		this.repository.clearConnector();
		this.repository.clearSession();
	}

	private clearReconnect(): void {
		if (!this.reconnectTimeout) {
			return;
		}

		clearTimeout(this.reconnectTimeout);
		this.reconnectTimeout = null;
	}

	private async connectRelay(): Promise<void> {
		if (!this.connector || !this.localServerBaseUrl) {
			return;
		}

		this.clearReconnect();
		this.relayClient.start({
			connectorId: this.connector.connectorId,
			connectorToken: this.connector.connectorToken,
			localServerBaseUrl: this.localServerBaseUrl,
			privateBackendUrl: this.connector.backendUrl,
		});
	}

	private async ensureConnector(allowRebootstrap: boolean): Promise<void> {
		if (!this.session) {
			return;
		}

		if (this.connector && this.localServerBaseUrl) {
			try {
				await this.connectRelay();
				return;
			} catch (error) {
				this.errorMessage = toPrivateAccountErrorMessage(error, "private_relay_connect_failed");
				if (!allowRebootstrap) {
					return;
				}
			}
		}

		const bootstrap = await this.withPrivateAuth(async (client) =>
			await client.bootstrapConnector({
				hostname: readHostname(),
				name: this.options.connectorName ?? "Desktop Connector",
				relayCapabilitiesVersion: "1",
				relayVersion: "1.0.0",
			})
		);
		await this.withPrivateAuth(async (client) =>
			await client.claimPairing({
				pairingCode: bootstrap.pairing.code,
			})
		);
		const status = await this.withPrivateAuth(async (client) =>
			await client.getBootstrapStatus({
				pairingId: bootstrap.pairing.id,
				pollToken: bootstrap.pairing.pollToken,
			})
		);

		if (!status.connector.accessToken) {
			throw new Error("private_connector_token_missing");
		}

		this.connector = {
			backendUrl: this.options.backendUrl,
			connectorId: status.connector.id,
			connectorName: bootstrap.connector.name,
			connectorToken: status.connector.accessToken,
		};
		this.repository.saveConnector(this.connector);
		await this.connectRelay();
	}

	private async handleLocalRequest(input: {
		body: string | null;
		headers: Record<string, string>;
		method: string;
		path: string;
	}): Promise<{
		body: string | null;
		headers: Record<string, string>;
		status: number;
	}> {
		if (!this.localApp) {
			throw new Error("private_local_app_unavailable");
		}

		const headers = new Headers(input.headers);
		headers.set("authorization", `Bearer ${this.options.localServerToken}`);
		const response = await this.localApp.handle(
			new Request(`http://127.0.0.1${input.path}`, {
				body: input.body ?? undefined,
				headers,
				method: input.method,
			}),
		);

		return {
			body: response.status === 204 ? null : await response.text(),
			headers: Object.fromEntries(response.headers.entries()),
			status: response.status,
		};
	}

	private async ensureMobileConnectLink(): Promise<void> {
		if (!this.session || !this.connector) {
			this.mobileConnectLink = null;
			return;
		}

		const now = Date.now();
		const expiresAt = this.mobileConnectLink?.expiresAt
			? new Date(this.mobileConnectLink.expiresAt).getTime()
			: Number.NaN;
		const needsRefresh = (
			!this.mobileConnectLink
			|| this.mobileConnectLink.connectorId !== this.connector.connectorId
			|| now - this.mobileConnectLink.generatedAtMs >= (this.options.mobileConnectRefreshIntervalMs ?? DEFAULT_MOBILE_CONNECT_REFRESH_INTERVAL_MS)
			|| !Number.isFinite(expiresAt)
			|| expiresAt <= now
		);
		if (!needsRefresh) {
			return;
		}

		const connectorId = this.connector.connectorId;
		const bootstrap = await this.withPrivateAuth(async (client) =>
			await client.createMobileConnectBootstrap({
				connectorId,
			}),
		);

		this.mobileConnectLink = {
			connectorId: bootstrap.connector.id,
			expiresAt: bootstrap.expiresAt,
			generatedAtMs: now,
			linkUrl: bootstrap.linkUrl,
		};
	}

	private async refreshSession(): Promise<void> {
		if (!this.session?.refreshToken) {
			throw new PrivateApiError(401, null, "missing_private_refresh_token");
		}

		const client = createPrivateClient({
			baseUrl: this.options.backendUrl,
		});
		this.session = await client.refresh({
			refreshToken: this.session.refreshToken,
		});
		this.repository.saveSession(this.session);
	}

	private scheduleReconnect(): void {
		if (this.reconnectTimeout || !this.session || !this.connector) {
			return;
		}

		this.reconnectTimeout = setTimeout(() => {
			this.reconnectTimeout = null;
			void this.ensureConnector(false);
		}, this.options.reconnectDelayMs ?? 1_000);
		this.reconnectTimeout.unref?.();
	}

	private snapshot(): PrivateAccountStateSnapshot {
		const qrPayload: DesktopMobileConnectQrPayloadDto | null = this.connector && this.mobileConnectLink
			? {
				backendUrl: this.connector.backendUrl,
				connectorId: this.connector.connectorId,
				connectorName: this.connector.connectorName,
				linkUrl: this.mobileConnectLink.linkUrl,
				type: "remotecode_private_mobile_connect",
				version: 1,
			}
			: null;

		return {
			connector: this.connectorDto,
			connectorRelayState: this.connectorRelayState,
			errorMessage: this.errorMessage,
			qrPayload,
			user: this.session?.user ?? null,
		};
	}

	private async withPrivateAuth<T>(
		callback: (client: ReturnType<typeof createPrivateClient>) => Promise<T>,
	): Promise<T> {
		if (!this.session) {
			throw new PrivateApiError(401, null, "private_session_missing");
		}

		const createAuthedClient = () =>
			createPrivateClient({
				baseUrl: this.options.backendUrl,
				getAccessToken: () => this.session?.accessToken ?? null,
			});

		try {
			return await callback(createAuthedClient());
		} catch (error) {
			if (!(error instanceof PrivateApiError) || error.status !== 401) {
				throw error;
			}

			await this.refreshSession();
			return await callback(createAuthedClient());
		}
	}
}

export const createPrivateAccountService = (
	repository: PrivateAccountRepository,
	options: PrivateAccountServiceOptions,
) => new PrivateAccountService(repository, options);
