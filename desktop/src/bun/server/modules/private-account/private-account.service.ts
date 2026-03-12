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
import {
	maskEmailForLogs,
	maskTokenForLogs,
	serverLogger,
	toLogErrorDetails,
} from "../../shared/core/server-logger";
import { RelayConnectorClient } from "./relay-connector.client";
import type { PersistedPrivateConnector, PrivateAccountAuthInput, PrivateAccountStateSnapshot } from "./private-account.model";
import { PrivateAccountRepository } from "./private-account.repository";

interface PrivateAccountServiceOptions {
	backendUrl: string;
	clock?: () => Date;
	connectorName?: string;
	heartbeatIntervalMs?: number;
	localServerToken: string;
	mobileConnectRefreshIntervalMs?: number;
	platform?: NodeJS.Platform;
	publicWebUrl?: string;
	reconnectDelayMs?: number;
}

interface MobileConnectQrLink {
	connectorId: string;
	expiresAt: string;
	generatedAtMs: number;
	linkUrl: string;
}

const DEFAULT_MOBILE_CONNECT_REFRESH_INTERVAL_MS = 5_000;
const DEFAULT_PUBLIC_WEB_URL = "https://remotecode.io";

const PRIVATE_ACCOUNT_ERROR_MESSAGES: Record<string, string> = {
	private_backend_unreachable: "Unable to connect. Is the computer able to access the url?",
	missing_private_refresh_token: "Your session has expired. Please sign in again.",
	private_connector_token_missing: "Desktop pairing could not be completed. Please try again.",
	private_local_app_unavailable: "The local desktop service is unavailable. Please restart the app.",
	private_relay_connect_failed: "The desktop relay could not connect. Please try again.",
	private_relay_socket_error: "The desktop relay connection failed. Please try again.",
	private_state_refresh_failed: "We couldn't refresh your private account state. Please try again.",
};

const createStatusError = (message: string, status: number): Error & { status: number } =>
	Object.assign(new Error(message), { status });

const isPrivateBackendUnreachableError = (error: unknown): boolean => {
	if (!(error instanceof Error) || error instanceof PrivateApiError) {
		return false;
	}

	const message = error.message.toLowerCase();
	return message.includes("fetch failed")
		|| message.includes("failed to fetch")
		|| message.includes("unable to connect")
		|| message.includes("econnrefused")
		|| message.includes("enotfound");
};

const toPrivateBackendServiceError = (error: unknown): Error => {
	if (error instanceof PrivateApiError) {
		return error;
	}

	if (error instanceof Error && PRIVATE_ACCOUNT_ERROR_MESSAGES[error.message]) {
		return error;
	}

	if (isPrivateBackendUnreachableError(error)) {
		return createStatusError("private_backend_unreachable", 503);
	}

	return error instanceof Error ? error : createStatusError("private_account_request_failed", 500);
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
				serverLogger.error("private-account", "Relay reported an error", {
					relayState: this.connectorRelayState,
					message,
				});
			},
			onStateChange: (state) => {
				const previousState = this.connectorRelayState;
				this.connectorRelayState = state;
				serverLogger.info("private-account", "Relay state changed", {
					connectorId: this.connector?.connectorId ?? null,
					nextState: state,
					previousState,
				});
				if (state === "disconnected" && this.session && this.connector) {
					this.scheduleReconnect();
				}
			},
		});
	}

	public async attachRuntime(input: { app: ServerApp; baseUrl: string }): Promise<void> {
		this.localApp = input.app;
		this.localServerBaseUrl = input.baseUrl.replace(/\/+$/u, "");
		serverLogger.info("private-account", "Runtime attached", {
			localServerBaseUrl: this.localServerBaseUrl,
			privateBackendUrl: this.options.backendUrl,
		});
		await this.resume();
	}

	public async getState(): Promise<PrivateAccountStateDto> {
		if (this.session && this.connector) {
			try {
				const connectors = await this.withPrivateAuth(async (client) => await client.listConnectors());
				this.connectorDto = connectors.connectors.find((item) => item.id === this.connector?.connectorId) ?? null;
				if (this.session.user.subscribed) {
					await this.ensureMobileConnectLink();
				} else {
					this.mobileConnectLink = null;
				}
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
		const startedAt = Date.now();
		serverLogger.info("private-account", "Login started", {
			email: maskEmailForLogs(input.email),
			privateBackendUrl: this.options.backendUrl,
		});
		try {
			const client = createPrivateClient({
				baseUrl: this.options.backendUrl,
			});
			this.session = await client.login(input);
			serverLogger.success("private-account", "Login upstream accepted", {
				durationMs: serverLogger.traceDurationMs(startedAt),
				email: maskEmailForLogs(this.session.user.email),
				refreshToken: maskTokenForLogs(this.session.refreshToken),
				userId: this.session.user.id,
			});
			this.repository.saveSession(this.session);
			this.errorMessage = null;
			await this.ensureConnector(true);
			return await this.getState();
		} catch (error) {
			serverLogger.error("private-account", "Login failed", {
				durationMs: serverLogger.traceDurationMs(startedAt),
				email: maskEmailForLogs(input.email),
				privateBackendUrl: this.options.backendUrl,
				...toLogErrorDetails(error),
			});
			throw toPrivateBackendServiceError(error);
		}
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

	public async buildBrowserRegisterUrl(input?: { email?: string }): Promise<{ url: string }> {
		return {
			url: this.buildPublicWebUrl("/register", {
				...(input?.email?.trim() ? { email: input.email.trim() } : {}),
				backendUrl: this.options.backendUrl,
				platform: this.resolveDesktopPlatform(),
				returnUrl: this.resolveDesktopReturnUrl(),
				target: "desktop",
			}),
		};
	}

	public async buildBrowserForgotPasswordUrl(input?: { email?: string }): Promise<{ url: string }> {
		return {
			url: this.buildPublicWebUrl("/forgot-password", {
				...(input?.email?.trim() ? { email: input.email.trim() } : {}),
				backendUrl: this.options.backendUrl,
			}),
		};
	}

	public async buildBrowserManageSubscriptionUrl(): Promise<{ url: string }> {
		return {
			url: this.buildPublicWebUrl("/app"),
		};
	}

	public async completeBrowserReturn(input: {
		backendUrl?: string;
		completionToken: string;
	}): Promise<PrivateAccountStateDto> {
		const completionToken = input.completionToken.trim();
		if (completionToken.length === 0) {
			throw createStatusError("auth_completion_token_required", 400);
		}

		const client = createPrivateClient({
			baseUrl: (input.backendUrl?.trim().replace(/\/+$/u, "") || this.options.backendUrl),
		});
		this.session = await client.exchangeCompletionToken({
			completionToken,
		});
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
		serverLogger.info("private-account", "Connecting relay", {
			connectorId: this.connector.connectorId,
			localServerBaseUrl: this.localServerBaseUrl,
			privateBackendUrl: this.connector.backendUrl,
		});
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
				serverLogger.debug("private-account", "Reusing existing connector", {
					allowRebootstrap,
					connectorId: this.connector.connectorId,
				});
				await this.connectRelay();
				return;
			} catch (error) {
				serverLogger.warn("private-account", "Existing connector failed, fallback to bootstrap", {
					allowRebootstrap,
					connectorId: this.connector.connectorId,
					...toLogErrorDetails(error),
				});
				this.errorMessage = toPrivateAccountErrorMessage(error, "private_relay_connect_failed");
				if (!allowRebootstrap) {
					return;
				}
			}
		}

		serverLogger.info("private-account", "Bootstrapping connector", {
			allowRebootstrap,
			connectorName: this.options.connectorName ?? "Desktop Connector",
			hostname: readHostname(),
			privateBackendUrl: this.options.backendUrl,
		});
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
		serverLogger.success("private-account", "Connector bootstrapped", {
			connectorId: this.connector.connectorId,
			connectorName: this.connector.connectorName,
			connectorToken: maskTokenForLogs(this.connector.connectorToken),
		});
		this.repository.saveConnector(this.connector);
		await this.connectRelay();
	}

	private buildPublicWebUrl(path: string, params?: Record<string, string>): string {
		const url = new URL(path, `${(this.options.publicWebUrl ?? DEFAULT_PUBLIC_WEB_URL).replace(/\/+$/u, "")}/`);
		for (const [key, value] of Object.entries(params ?? {})) {
			url.searchParams.set(key, value);
		}

		return url.toString();
	}

	private resolveDesktopPlatform(): "linux" | "macos" | "windows" {
		const platform = this.options.platform ?? process.platform;
		if (platform === "win32") {
			return "windows";
		}

		if (platform === "darwin") {
			return "macos";
		}

		return "linux";
	}

	private resolveDesktopReturnUrl(): string {
		if (this.resolveDesktopPlatform() === "macos") {
			return "remotecode://auth/complete";
		}

		if (!this.localServerBaseUrl) {
			throw createStatusError("private_local_app_unavailable", 503);
		}

		return `${this.localServerBaseUrl}/v1/private-account/browser-return`;
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

		serverLogger.warn("private-account", "Refreshing expired session", {
			privateBackendUrl: this.options.backendUrl,
			refreshToken: maskTokenForLogs(this.session.refreshToken),
		});
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

		serverLogger.warn("private-account", "Scheduling relay reconnect", {
			connectorId: this.connector.connectorId,
			delayMs: this.options.reconnectDelayMs ?? 1_000,
		});
		this.reconnectTimeout = setTimeout(() => {
			this.reconnectTimeout = null;
			void this.ensureConnector(false);
		}, this.options.reconnectDelayMs ?? 1_000);
		this.reconnectTimeout.unref?.();
	}

	private snapshot(): PrivateAccountStateSnapshot {
		const qrPayload: DesktopMobileConnectQrPayloadDto | null = this.connector && this.mobileConnectLink && this.session?.user.subscribed
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
				throw toPrivateBackendServiceError(error);
			}

			serverLogger.warn("private-account", "Private API returned 401, retrying after refresh", {
				privateBackendUrl: this.options.backendUrl,
			});
			await this.refreshSession();
			try {
				return await callback(createAuthedClient());
			} catch (refreshError) {
				throw toPrivateBackendServiceError(refreshError);
			}
		}
	}
}

export const createPrivateAccountService = (
	repository: PrivateAccountRepository,
	options: PrivateAccountServiceOptions,
) => new PrivateAccountService(repository, options);
