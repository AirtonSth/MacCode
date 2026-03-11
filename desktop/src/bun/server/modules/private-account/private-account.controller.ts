import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { PrivateAccountService } from "./private-account.service";

const PRIVATE_ACCOUNT_ERROR_MESSAGES: Record<string, string> = {
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

	public build() {
		return new Elysia({ name: "private-account-controller" })
			.use(withRestAuth())
			.get("/private-account/state", async () => {
				return await this.service.getState();
			})
			.post(
				"/private-account/login",
				async ({ body }) => await this.service.login(body),
				{
					body: t.Object({
						email: t.String(),
						password: t.String(),
					}),
				},
			)
			.post(
				"/private-account/logout",
				async () => await this.service.logout(),
			)
			.post(
				"/private-account/register",
				async ({ body }) => await this.service.register(body),
				{
					body: t.Object({
						email: t.String(),
						password: t.String(),
					}),
				},
			)
			.onError(({ error, set }) => {
				if (!(error instanceof Error)) {
					return;
				}

				const status = (error as { status?: unknown }).status;

				set.status = typeof status === "number" ? status : 500;

				return {
					code: error.message,
					error: toFriendlyPrivateAccountError(error.message),
				};
			});
	}
}

export const createPrivateAccountController = (service: PrivateAccountService) =>
	PrivateAccountController.build(service);
