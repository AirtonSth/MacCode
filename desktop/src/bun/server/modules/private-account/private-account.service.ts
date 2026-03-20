import { hostname as readHostname } from "node:os";

import {
	createPrivateClient,
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
import {
	createRelayConnectorClient,
	type RelayConnectorOptions,
} from "./relay-connector.client";
import type { PersistedPrivateConnector, PrivateAccountAuthInput, PrivateAccountStateSnapshot } from "./private-account.model";
import { PrivateAccountRepository } from "./private-account.repository";

type RelayConnectorClientContract = Pick<
	ReturnType<typeof createRelayConnectorClient>,
	"getState" | "start" | "stop"
>;

interface PrivateAccountServiceOptions {
	backendUrl: string;
	clock?: () => Date;
	connectorName?: string;
	createRelayClient?: (options: RelayConnectorOptions) => RelayConnectorClientContract;
	heartbeatIntervalMs?: number;
	localServerToken: string;
	platform?: NodeJS.Platform;
	publicWebUrl?: string;
	reconnectMaxDelayMs?: number;
	reconnectDelayMs?: number;
}
const DEFAULT_PUBLIC_WEB_URL = "https://remotecode.io";
const DEFAULT_RECONNECT_DELAY_MS = 1_000;
const DEFAULT_RECONNECT_MAX_DELAY_MS = 15_000;
const PRIVATE_STATE_CACHE_TTL_MS = 15_000;

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

const normalizePrivateSession = (input: PrivateSessionDto): PrivateSessionDto => ({
	...input,
	user: {
		daysRemaing: input.user.daysRemaing,
		daysRemaining: input.user.daysRemaining,
		email: input.user.email.trim().toLowerCase(),
		id: input.user.id.trim(),
		subscribed: input.user.subscribed,
	},
});

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
	private errorSource: "relay" | "state" | null = null;
	private errorMessage: string | null = null;
	private localApp: ServerApp | null = null;
	private localServerBaseUrl: string | null = null;
	private stateRefreshPromise: Promise<void> | null = null;
	private lastStateRefreshAt = 0;
	private reconnectAttemptCount = 0;
	private reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
	private relayClient: RelayConnectorClientContract;
	private session: PrivateSessionDto | null;

	public constructor(
		private readonly repository: PrivateAccountRepository,
		private readonly options: PrivateAccountServiceOptions,
	) {
		const storedSession = this.repository.readSession();
		this.session = storedSession ? normalizePrivateSession(storedSession) : null;
		this.connector = this.repository.readConnector();
		this.relayClient = (options.createRelayClient ?? createRelayConnectorClient)({
			heartbeatIntervalMs: options.heartbeatIntervalMs,
			localRequestHandler: async (input) => await this.handleLocalRequest(input),
			localServerToken: options.localServerToken,
			onError: (message) => {
				this.setErrorMessage(toPrivateAccountErrorMessage(new Error(message), message), "relay");
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
				if (state === "connected") {
					this.reconnectAttemptCount = 0;
					this.clearReconnect();
					this.clearErrorMessage();
					return;
				}

				if ((state === "disconnected" || state === "error") && this.session && this.connector) {
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
				await this.refreshStateSnapshot();
				this.clearErrorMessage("state");
				if (this.localApp && this.localServerBaseUrl && (this.connectorRelayState === "idle" || this.connectorRelayState === "disconnected" || this.connectorRelayState === "error")) {
					this.scheduleReconnect();
				}
			} catch (error) {
				this.setErrorMessage(toPrivateAccountErrorMessage(error, "private_state_refresh_failed"), "state");
			}
		} else {
			this.connectorDto = null;
		}

		const snapshot = this.snapshot();
		return {
			authenticated: Boolean(snapshot.user),
			connector: snapshot.connector,
			connectorRelayState: snapshot.connectorRelayState,
			errorMessage: snapshot.errorMessage,
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
			this.session = normalizePrivateSession(await client.login(input));
			serverLogger.success("private-account", "Login upstream accepted", {
				durationMs: serverLogger.traceDurationMs(startedAt),
				email: maskEmailForLogs(this.session.user.email),
				refreshToken: maskTokenForLogs(this.session.refreshToken),
				userId: this.session.user.id,
			});
			this.repository.saveSession(this.session);
			this.lastStateRefreshAt = 0;
			this.clearErrorMessage();
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
		this.session = normalizePrivateSession(await client.exchangeCompletionToken({
			completionToken,
		}));
		this.repository.saveSession(this.session);
		this.lastStateRefreshAt = 0;
		this.clearErrorMessage();
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
		this.clearErrorMessage();
		this.stateRefreshPromise = null;
		this.lastStateRefreshAt = 0;
		this.reconnectAttemptCount = 0;
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
		try {
			this.relayClient.start({
				connectorId: this.connector.connectorId,
				connectorToken: this.connector.connectorToken,
				localServerBaseUrl: this.localServerBaseUrl,
				privateBackendUrl: this.connector.backendUrl,
			});
		} catch (error) {
			serverLogger.error("private-account", "Relay start threw synchronously", {
				connectorId: this.connector.connectorId,
				...toLogErrorDetails(error),
			});
			this.setErrorMessage(toPrivateAccountErrorMessage(error, "private_relay_connect_failed"), "relay");
			this.connectorRelayState = "error";
			this.scheduleReconnect();
		}
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
				this.setErrorMessage(toPrivateAccountErrorMessage(error, "private_relay_connect_failed"), "relay");
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
		this.lastStateRefreshAt = 0;
		await this.connectRelay();
	}

	private clearErrorMessage(source?: "relay" | "state"): void {
		if (source && this.errorSource !== source) {
			return;
		}

		this.errorMessage = null;
		this.errorSource = null;
	}

	private setErrorMessage(message: string | null, source: "relay" | "state"): void {
		this.errorMessage = message;
		this.errorSource = message ? source : null;
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
		bodyEncoding?: "utf8" | "base64";
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

		const responseHeaders = Object.fromEntries(response.headers.entries());
		const contentEncoding = response.headers.get("content-encoding");
		const contentType = response.headers.get("content-type");
		const isTextualContentType = contentType
			? (
				contentType.toLowerCase().startsWith("text/")
				|| contentType.toLowerCase().includes("application/json")
				|| contentType.toLowerCase().includes("application/javascript")
				|| contentType.toLowerCase().includes("application/xml")
				|| contentType.toLowerCase().includes("application/x-www-form-urlencoded")
			)
			: false;
		const shouldRelayAsBinary = Boolean(contentEncoding) || !isTextualContentType;
		if (shouldRelayAsBinary) {
			const bodyBuffer = response.status === 204 ? null : Buffer.from(await response.arrayBuffer()).toString("base64");
			return {
				body: bodyBuffer,
				bodyEncoding: "base64",
				headers: responseHeaders,
				status: response.status,
			};
		}

		return {
			body: response.status === 204 ? null : await response.text(),
			headers: responseHeaders,
			status: response.status,
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
		this.session = normalizePrivateSession(await client.refresh({
			refreshToken: this.session.refreshToken,
		}));
		this.repository.saveSession(this.session);
		this.lastStateRefreshAt = 0;
	}

	private async refreshSessionFromBackend(): Promise<void> {
		if (!this.session) {
			return;
		}

		const response = await this.withPrivateAuth(async (client) => await client.me());
		this.session = normalizePrivateSession({
			accessToken: this.session.accessToken,
			refreshToken: this.session.refreshToken,
			user: response.user,
		});
		this.repository.saveSession(this.session);
		this.lastStateRefreshAt = 0;
	}

	private async refreshStateSnapshot(force = false): Promise<void> {
		const now = Date.now();
		if (!force && now - this.lastStateRefreshAt < PRIVATE_STATE_CACHE_TTL_MS) {
			return;
		}

		if (this.stateRefreshPromise) {
			await this.stateRefreshPromise;
			return;
		}

		this.stateRefreshPromise = (async () => {
			await this.refreshSessionFromBackend();
			await this.refreshConnectorState();
			this.lastStateRefreshAt = Date.now();
		})();

		try {
			await this.stateRefreshPromise;
		} finally {
			this.stateRefreshPromise = null;
		}
	}

	private scheduleReconnect(): void {
		if (this.reconnectTimeout || !this.session || !this.connector) {
			return;
		}

		const baseDelayMs = this.options.reconnectDelayMs ?? DEFAULT_RECONNECT_DELAY_MS;
		const maxDelayMs = this.options.reconnectMaxDelayMs ?? DEFAULT_RECONNECT_MAX_DELAY_MS;
		const delayMs = Math.min(baseDelayMs * 2 ** this.reconnectAttemptCount, maxDelayMs);
		this.reconnectAttemptCount += 1;
		serverLogger.warn("private-account", "Scheduling relay reconnect", {
			connectorId: this.connector.connectorId,
			delayMs,
			reconnectAttemptCount: this.reconnectAttemptCount,
		});
		this.reconnectTimeout = setTimeout(() => {
			this.reconnectTimeout = null;
			void this.ensureConnector(false);
		}, delayMs);
		this.reconnectTimeout.unref?.();
	}

	private async refreshConnectorState(): Promise<void> {
		const connectorId = this.connector?.connectorId ?? "";
		if (!connectorId) {
			this.connectorDto = null;
			return;
		}

		const connectors = await this.withPrivateAuth(async (client) => await client.listConnectors());
		this.connectorDto = connectors.connectors.find((item) => item.id === connectorId) ?? null;

		if (this.connectorDto || !this.localApp || !this.localServerBaseUrl) {
			return;
		}

		serverLogger.warn("private-account", "Persisted connector no longer exists upstream, re-bootstrapping", {
			connectorId,
			privateBackendUrl: this.options.backendUrl,
		});
		this.relayClient.stop();
		this.repository.clearConnector();
		this.connector = null;
		await this.ensureConnector(true);

		if (!this.connector) {
			return;
		}

		const refreshedConnectors = await this.withPrivateAuth(async (client) => await client.listConnectors());
		this.connectorDto = refreshedConnectors.connectors.find((item) => item.id === this.connector?.connectorId) ?? null;
	}

	private snapshot(): PrivateAccountStateSnapshot {
		return {
			connector: this.connectorDto,
			connectorRelayState: this.connectorRelayState,
			errorMessage: this.errorMessage,
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
