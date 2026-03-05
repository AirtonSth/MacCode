import { createDatabaseClient } from "../shared/db/db.client";
import { initializeDatabaseSchema } from "../shared/db/db.bootstrap";
import { serverConfig } from "../config";
import { createLiveActivitySubscriptionRepository } from "../modules/live-activity/live-activity-subscription.repository";
import {
	createLiveActivityPushDebugClientFromEnvironment,
	type LiveActivityPushDebugSendInput,
} from "../modules/live-activity/live-activity-push.service";
import type { LiveActivityPhase } from "../modules/live-activity/live-activity-push.model";

type ScriptArgs = {
	chatId?: string;
	databasePath?: string;
	event: "update" | "end";
	phase?: LiveActivityPhase;
	preview?: string;
	statusLine?: string;
};

const parseArgs = (argv: string[]): ScriptArgs => {
	const args: ScriptArgs = {
		event: "update",
	};

	for (const rawArg of argv) {
		if (!rawArg.startsWith("--")) {
			continue;
		}

		const [rawKey, ...valueParts] = rawArg.slice(2).split("=");
		const value = valueParts.join("=").trim();

		switch (rawKey) {
			case "chat-id": {
				args.chatId = value || undefined;
				break;
			}
			case "database-path": {
				args.databasePath = value || undefined;
				break;
			}
			case "event": {
				if (value === "update" || value === "end") {
					args.event = value;
				}
				break;
			}
			case "phase": {
				if (
					value === "background"
					|| value === "completed"
					|| value === "error"
					|| value === "failed"
					|| value === "finalizing"
					|| value === "running"
				) {
					args.phase = value;
				}
				break;
			}
			case "preview": {
				args.preview = value || undefined;
				break;
			}
			case "status-line": {
				args.statusLine = value || undefined;
				break;
			}
			default: {
				break;
			}
		}
	}

	return args;
};

const toTokenPreview = (token: string): string => (
	token.length <= 12
		? token
		: `${token.slice(0, 6)}...${token.slice(-4)}`
);

const main = async (): Promise<void> => {
	const args = parseArgs(process.argv.slice(2));
	const databaseClient = await createDatabaseClient(args.databasePath);

	try {
		initializeDatabaseSchema(databaseClient.sqlite);
		const repository = createLiveActivitySubscriptionRepository(databaseClient.orm);
		const allSubscriptions = repository.listAll();
		const subscriptions = args.chatId
			? allSubscriptions.filter((subscription) => subscription.chatId === args.chatId)
			: allSubscriptions;

		console.info("[live-activity-test] database", {
			configuredDatabasePath: serverConfig.databasePath ?? "(default)",
			resolvedDatabasePath: databaseClient.dbPath,
		});
		console.info("[live-activity-test] subscriptions", {
			filteredChatId: args.chatId ?? "(all)",
			totalInDatabase: allSubscriptions.length,
			totalSelected: subscriptions.length,
		});

		const debugClient = createLiveActivityPushDebugClientFromEnvironment({
			apnsAuthKeyId: serverConfig.liveActivityApnsAuthKeyId,
			apnsPrivateKeyPath: serverConfig.liveActivityApnsPrivateKeyPath,
			apnsTeamId: serverConfig.liveActivityApnsTeamId,
			apnsUseSandbox: serverConfig.liveActivityApnsUseSandbox,
			bundleIdentifier: serverConfig.liveActivityBundleIdentifier ?? "",
			firebaseProjectId: serverConfig.liveActivityFirebaseProjectId,
			serviceAccountPath: serverConfig.liveActivityServiceAccountPath,
		});

		console.info("[live-activity-test] sender", {
			enabled: debugClient.getIsEnabled(),
			supportedPushTokenTypes: [...debugClient.getSupportedPushTokenTypes()],
		});

		if (subscriptions.length === 0) {
			console.info("[live-activity-test] nothing to send");
			return;
		}

		if (!debugClient.getIsEnabled()) {
			console.error("[live-activity-test] sender is not configured from environment");
			process.exitCode = 1;
			return;
		}

		let deliveredCount = 0;
		let droppedCount = 0;
		let failedCount = 0;

		for (const subscription of subscriptions) {
			const sendInput: LiveActivityPushDebugSendInput = {
				chatId: subscription.chatId,
				chatTitle: subscription.chatTitle ?? "Manual Live Activity Debug",
				event: args.event,
				liveActivityToken: subscription.liveActivityToken,
				phase: args.phase,
				preview: args.preview ?? `Manual backend ${args.event} at ${new Date().toISOString()}`,
				pushToken: subscription.pushToken,
				pushTokenType: subscription.pushTokenType,
				statusLine: args.statusLine ?? "Backend live activity test",
			};

			const result = await debugClient.send(sendInput);
			if (result.delivered) {
				deliveredCount += 1;
			} else {
				failedCount += 1;
			}
			if (result.shouldDropSubscription) {
				droppedCount += 1;
			}

			console.info("[live-activity-test] send-result", {
				chatId: subscription.chatId,
				chatTitle: subscription.chatTitle ?? "Thread",
				delivered: result.delivered,
				errorCode: result.errorCode ?? null,
				liveActivityToken: toTokenPreview(subscription.liveActivityToken),
				pushToken: toTokenPreview(subscription.pushToken),
				pushTokenType: subscription.pushTokenType,
				shouldDropSubscription: result.shouldDropSubscription,
				updatedAt: subscription.updatedAt,
			});
		}

		console.info("[live-activity-test] summary", {
			deliveredCount,
			droppedCount,
			event: args.event,
			failedCount,
			totalSelected: subscriptions.length,
		});

		if (deliveredCount === 0) {
			process.exitCode = 1;
		}
	} finally {
		databaseClient.close();
	}
};

await main();
