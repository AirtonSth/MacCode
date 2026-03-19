import type {
	LiveActivityPushFinishInput,
	LiveActivityPushTokenType,
	ThreadCompletionPushStoredSubscription,
	ThreadCompletionPushSubscriptionMutationInput,
	ThreadCompletionPushSubscriptionStoreContract,
} from "./live-activity-push.model";

interface ThreadCompletionPushConnectorCredentials {
	backendUrl?: string | null;
	connectorId: string;
	connectorToken: string;
}

interface ThreadCompletionPushEnvironmentInput {
	getConnectorCredentials: () => ThreadCompletionPushConnectorCredentials | null;
	privateBackendUrl: string;
	subscriptionStore?: ThreadCompletionPushSubscriptionStoreContract;
}

interface ThreadCompletionAlertInput {
	body: string;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	title: string;
	data?: Record<string, string>;
}

interface ThreadCompletionAlertResult {
	delivered: boolean;
	errorCode?: string;
	shouldDropSubscription: boolean;
}

type ThreadCompletionAlertSender = (input: ThreadCompletionAlertInput) => Promise<ThreadCompletionAlertResult>;

const PRIVATE_BACKEND_PUSH_TIMEOUT_MS = 5_000;

const toNormalized = (value: string | null | undefined): string => value?.trim() ?? "";
const toOptionalText = (value: string | undefined): string | undefined => {
	const normalized = value?.trim();
	return normalized && normalized.length > 0 ? normalized : undefined;
};
const toSubscriptionKey = (input: { chatId: string; pushToken: string; pushTokenType: LiveActivityPushTokenType }): string =>
	`${input.chatId}::${input.pushTokenType}::${input.pushToken}`;

const buildCompletionAlert = (
	input: LiveActivityPushFinishInput,
): { body: string; title: string } => {
	const chatTitle = toOptionalText(input.chatTitle) ?? "Thread";
	if (input.outcome === "completed") {
		return {
			title: "Thread finished",
			body: `${chatTitle} response is ready.`,
		};
	}

	return {
		title: "Thread failed",
		body: `${chatTitle} ended with an error.`,
	};
};

const createNoopThreadCompletionAlertSender = (): ThreadCompletionAlertSender => async () => ({
	delivered: false,
	errorCode: "push/no-connector-credentials",
	shouldDropSubscription: false,
});

const createPrivateBackendThreadCompletionAlertSender = (
	input: Pick<ThreadCompletionPushEnvironmentInput, "getConnectorCredentials" | "privateBackendUrl">,
): ThreadCompletionAlertSender => async (alertInput) => {
	const credentials = input.getConnectorCredentials();
	if (!credentials) {
		return {
			delivered: false,
			errorCode: "push/no-connector-credentials",
			shouldDropSubscription: false,
		};
	}

	const backendUrl = credentials.backendUrl || input.privateBackendUrl;
	const url = `${backendUrl.replace(/\/+$/u, "")}/v1/private/push-notification/alert`;

	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), PRIVATE_BACKEND_PUSH_TIMEOUT_MS);
		const response = await fetch(url, {
			method: "POST",
			headers: {
				"content-type": "application/json",
				"x-connector-id": credentials.connectorId,
				"x-connector-token": credentials.connectorToken,
			},
			body: JSON.stringify(alertInput),
			signal: controller.signal,
		});
		clearTimeout(timeout);

		if (!response.ok) {
			return {
				delivered: false,
				errorCode: `push/backend-status-${response.status}`,
				shouldDropSubscription: false,
			};
		}

		const parsed = await response.json() as ThreadCompletionAlertResult;
		return {
			delivered: parsed.delivered ?? false,
			errorCode: parsed.errorCode,
			shouldDropSubscription: parsed.shouldDropSubscription ?? false,
		};
	} catch (error) {
		const isTimeout = error instanceof Error && error.name === "AbortError";
		return {
			delivered: false,
			errorCode: isTimeout ? "push/backend-timeout" : "push/backend-error",
			shouldDropSubscription: false,
		};
	}
};

export class ThreadCompletionPushService {
	private readonly subscriptions = new Map<string, ThreadCompletionPushStoredSubscription>();

	constructor(
		private readonly sender: ThreadCompletionAlertSender,
		private readonly subscriptionStore?: ThreadCompletionPushSubscriptionStoreContract,
	) {
		const stored = this.subscriptionStore?.listAll() ?? [];
		for (const subscription of stored) {
			this.subscriptions.set(toSubscriptionKey(subscription), subscription);
		}
	}

	async upsertSubscription(input: ThreadCompletionPushSubscriptionMutationInput): Promise<boolean> {
		const pushToken = toNormalized(input.pushToken);
		if (pushToken.length === 0 || (input.pushTokenType !== "apns" && input.pushTokenType !== "fcm")) {
			return false;
		}

		const normalizedInput = {
			chatId: input.chatId,
			chatTitle: toOptionalText(input.chatTitle),
			pushToken,
			pushTokenType: input.pushTokenType,
		} satisfies Omit<ThreadCompletionPushStoredSubscription, "updatedAt">;
		const key = toSubscriptionKey(normalizedInput);

		if (!input.enabled) {
			this.subscriptions.delete(key);
			this.subscriptionStore?.deleteExact(normalizedInput);
			return false;
		}

		const stored = this.subscriptionStore?.upsert(normalizedInput) ?? {
			...normalizedInput,
			updatedAt: new Date().toISOString(),
		};
		this.subscriptions.set(key, stored);
		return true;
	}

	async onChatFinished(input: LiveActivityPushFinishInput): Promise<void> {
		const alert = buildCompletionAlert(input);
		const matchingSubscriptions = [...this.subscriptions.values()].filter(
			(subscription) => subscription.chatId === input.chatId,
		);

		for (const subscription of matchingSubscriptions) {
			const result = await this.sender({
				body: alert.body,
				title: alert.title,
				pushToken: subscription.pushToken,
				pushTokenType: subscription.pushTokenType,
				data: {
					chatId: input.chatId,
					outcome: input.outcome,
				},
			});
			if (!result.shouldDropSubscription) {
				continue;
			}

			const key = toSubscriptionKey(subscription);
			this.subscriptions.delete(key);
			this.subscriptionStore?.deleteExact(subscription);
		}
	}
}

export const createThreadCompletionPushServiceFromEnvironment = (
	input: ThreadCompletionPushEnvironmentInput,
): ThreadCompletionPushService =>
	new ThreadCompletionPushService(
		createPrivateBackendThreadCompletionAlertSender(input),
		input.subscriptionStore,
	);

export const createNoopThreadCompletionPushService = (): ThreadCompletionPushService =>
	new ThreadCompletionPushService(createNoopThreadCompletionAlertSender());
