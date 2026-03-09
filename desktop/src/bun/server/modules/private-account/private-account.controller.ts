import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import type { PrivateAccountService } from "./private-account.service";

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
			);
	}
}

export const createPrivateAccountController = (service: PrivateAccountService) =>
	PrivateAccountController.build(service);

