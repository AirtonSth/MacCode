import { Elysia, t } from "elysia";

import { withRestAuth } from "../../shared/auth/auth.service";
import { readMutationRequestMetadata } from "../../shared/core/request-context";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { TerminalService } from "./terminal.service";

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 1_000;

const normalizeCursor = (cursor: unknown): number | undefined => {
	if (typeof cursor !== "number" || !Number.isFinite(cursor) || cursor <= 0) {
		return undefined;
	}

	return Math.floor(cursor);
};

const normalizeLimit = (limit: unknown): number => {
	if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
		return DEFAULT_LIMIT;
	}

	return Math.min(MAX_LIMIT, Math.floor(limit));
};

export class TerminalController {
	static build(service: TerminalService, workspaceEvents?: WorkspaceEventsServiceContract) {
		return new TerminalController(service, workspaceEvents).build();
	}

	constructor(
		private readonly service: TerminalService,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
	) {}

	build() {
		return new Elysia({ name: "terminal-controller" })
			.use(withRestAuth())
			.get(
				"/chats/:id/terminal",
				async ({ params: parameters, query, set }) => {
					const result = await this.service.getHistoryByChatId(parameters.id, {
						cursor: normalizeCursor(query.cursor),
						limit: normalizeLimit(query.limit),
					});

					if (!result.chatExists) {
						set.status = 404;
						return { error: "chat not found" };
					}

					return {
						commands: result.commands,
						entries: result.entries,
					};
				},
				{
					query: t.Object({
						cursor: t.Optional(t.Numeric()),
						limit: t.Optional(t.Numeric()),
					}),
				},
			)
			.post(
				"/chats/:id/terminal/exec",
				async ({ body, params: parameters, request, set }) => {
					const normalizedCommand = body.command.trim();
					if (!normalizedCommand) {
						set.status = 400;
						return { error: "command is required" };
					}

					const result = await this.service.execCommand({
						chatId: parameters.id,
						command: normalizedCommand,
						timeoutMs: body.timeoutMs,
					});

					if (!result.chatExists) {
						set.status = 404;
						return { error: "chat not found" };
					}

					if (!result.projectExists) {
						set.status = 404;
						return { error: "project not found" };
					}

					if (!result.command) {
						set.status = 500;
						return { error: "terminal command not available" };
					}

					const metadata = readMutationRequestMetadata(request);
					this.workspaceEvents?.append({
						type: "terminal_command_started",
						payload: {
							command: {
								...result.command,
								status: "running",
							},
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					for (const entry of result.entries) {
						this.workspaceEvents?.append({
							type: "terminal_entry_appended",
							payload: {
								entry,
							},
							originClientId: metadata.clientId,
							requestId: metadata.requestId,
						});
					}

					this.workspaceEvents?.append({
						type: "terminal_command_finished",
						payload: {
							command: result.command,
						},
						originClientId: metadata.clientId,
						requestId: metadata.requestId,
					});

					return {
						command: result.command,
						entries: result.entries,
					};
				},
				{
					body: t.Object({
						command: t.String(),
						timeoutMs: t.Optional(t.Numeric()),
					}),
				},
			);
	}
}

export const createTerminalController = (
	service: TerminalService,
	workspaceEvents?: WorkspaceEventsServiceContract,
) => TerminalController.build(service, workspaceEvents);
