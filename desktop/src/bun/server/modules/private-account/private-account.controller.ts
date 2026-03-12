import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { maskEmailForLogs, serverLogger, toLogErrorDetails } from "../../shared/core/server-logger";
import type { PrivateAccountService } from "./private-account.service";

const PRIVATE_ACCOUNT_ERROR_MESSAGES: Record<string, string> = {
	private_backend_unreachable: "Unable to connect. Is the computer able to access the url?",
	missing_private_refresh_token: "Your session has expired. Please sign in again.",
	private_connector_token_missing: "Desktop pairing could not be completed. Please try again.",
	private_local_app_unavailable: "The local desktop service is unavailable. Please restart the app.",
	private_relay_connect_failed: "The desktop relay could not connect. Please try again.",
	private_relay_socket_error: "The desktop relay connection failed. Please try again.",
	private_state_refresh_failed: "We couldn't refresh your private account state. Please try again.",
	unauthorized: "You are not authorized to access this desktop server.",
};

const toFriendlyPrivateAccountError = (message: string): string =>
	PRIVATE_ACCOUNT_ERROR_MESSAGES[message]
		?? (message.includes("_") ? "Something went wrong. Please try again." : message);

export class PrivateAccountController {
	static build(service: PrivateAccountService) {
		return new PrivateAccountController(service).build();
	}

	public constructor(private readonly service: PrivateAccountService) {}

	private logRequestStart(input: {
		email?: string;
		method: string;
		origin: string | null;
		path: string;
		requestId: string;
	}): number {
		const startedAt = Date.now();
		serverLogger.info("private-account", "Request started", {
			email: maskEmailForLogs(input.email),
			method: input.method,
			origin: input.origin,
			path: input.path,
			requestId: input.requestId,
		});
		return startedAt;
	}

	private logRequestSuccess(input: {
		durationMs: number;
		requestId: string;
		status: number;
	}): void {
		serverLogger.success("private-account", "Request completed", input);
	}

	private logRequestFailure(input: {
		durationMs: number;
		error: unknown;
		requestId: string;
	}): void {
		serverLogger.error("private-account", "Request failed", {
			durationMs: input.durationMs,
			requestId: input.requestId,
			...toLogErrorDetails(input.error),
		});
	}

	private toErrorResponse(error: unknown): Response | undefined {
		if (!(error instanceof Error)) {
			return undefined;
		}

		const status = (error as { status?: unknown }).status;
		const resolvedStatus = typeof status === "number" ? status : 500;

		return new Response(JSON.stringify({
			code: error.message,
			error: toFriendlyPrivateAccountError(error.message),
		}), {
			headers: {
				"content-type": "application/json; charset=utf-8",
			},
			status: resolvedStatus,
		});
	}

	public build() {
		return new Elysia({ name: "private-account-controller" })
			.use(withRestAuth())
			.get("/private-account/state", async ({ request }) => {
				const requestId = serverLogger.createRequestId("pa-state");
				const startedAt = this.logRequestStart({
					method: "GET",
					origin: request.headers.get("origin"),
					path: "/v1/private-account/state",
					requestId,
				});
				try {
					const response = await this.service.getState();
					this.logRequestSuccess({
						durationMs: serverLogger.traceDurationMs(startedAt),
						requestId,
						status: 200,
					});
					return response;
				} catch (error) {
					this.logRequestFailure({
						durationMs: serverLogger.traceDurationMs(startedAt),
						error,
						requestId,
					});
					return this.toErrorResponse(error);
				}
			})
			.post(
				"/private-account/login",
				async ({ body, request }) => {
					const requestId = serverLogger.createRequestId("pa-login");
					const startedAt = this.logRequestStart({
						email: body.email,
						method: "POST",
						origin: request.headers.get("origin"),
						path: "/v1/private-account/login",
						requestId,
					});
					try {
						const response = await this.service.login(body);
						this.logRequestSuccess({
							durationMs: serverLogger.traceDurationMs(startedAt),
							requestId,
							status: 200,
						});
						return response;
					} catch (error) {
						this.logRequestFailure({
							durationMs: serverLogger.traceDurationMs(startedAt),
							error,
							requestId,
						});
						return this.toErrorResponse(error);
					}
				},
				{
					body: t.Object({
						email: t.String(),
						password: t.String(),
					}),
				},
			)
			.post(
				"/private-account/logout",
				async ({ request }) => {
					const requestId = serverLogger.createRequestId("pa-logout");
					const startedAt = this.logRequestStart({
						method: "POST",
						origin: request.headers.get("origin"),
						path: "/v1/private-account/logout",
						requestId,
					});
					try {
						const response = await this.service.logout();
						this.logRequestSuccess({
							durationMs: serverLogger.traceDurationMs(startedAt),
							requestId,
							status: 200,
						});
						return response;
					} catch (error) {
						this.logRequestFailure({
							durationMs: serverLogger.traceDurationMs(startedAt),
							error,
							requestId,
						});
						return this.toErrorResponse(error);
					}
				},
			)
			.post(
				"/private-account/register",
				async ({ body, request }) => {
					const requestId = serverLogger.createRequestId("pa-register");
					const startedAt = this.logRequestStart({
						email: body.email,
						method: "POST",
						origin: request.headers.get("origin"),
						path: "/v1/private-account/register",
						requestId,
					});
					try {
						const response = await this.service.register(body);
						this.logRequestSuccess({
							durationMs: serverLogger.traceDurationMs(startedAt),
							requestId,
							status: 200,
						});
						return response;
					} catch (error) {
						this.logRequestFailure({
							durationMs: serverLogger.traceDurationMs(startedAt),
							error,
							requestId,
						});
						return this.toErrorResponse(error);
					}
				},
				{
					body: t.Object({
						email: t.String(),
						password: t.String(),
					}),
				},
			);
	}
}

export const createPrivateAccountController = (service: PrivateAccountService) =>
	PrivateAccountController.build(service);
