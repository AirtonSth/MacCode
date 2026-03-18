import { RemoteCodeRequestError } from "../../../shared/api/remotecode-client";

interface LiveActivitySubscriptionResponse {
	enabled: boolean;
	subscribed: boolean;
}

export type LiveActivitySubscriptionDecision =
	| { kind: "registered" }
	| { kind: "retry"; reason: string }
	| { kind: "local-only"; reason: string }
	| { kind: "clear"; reason: string };

export const resolveLiveActivitySubscriptionResponse = (
	response: LiveActivitySubscriptionResponse,
): LiveActivitySubscriptionDecision => {
	if (!response.enabled) {
		return {
			kind: "local-only",
			reason: "disabled",
		};
	}

	if (!response.subscribed) {
		return {
			kind: "retry",
			reason: "subscription-not-accepted",
		};
	}

	return {
		kind: "registered",
	};
};

export const resolveLiveActivitySubscriptionError = (
	error: unknown,
): LiveActivitySubscriptionDecision => {
	if (error instanceof RemoteCodeRequestError) {
		if (error.status === 404 && error.message.trim().toLowerCase() === "chat not found") {
			return {
				kind: "clear",
				reason: "chat-not-found",
			};
		}

		if (error.status === 400 || error.status === 404) {
			return {
				kind: "local-only",
				reason: `request-${error.status}`,
			};
		}
	}

	return {
		kind: "retry",
		reason: error instanceof Error ? error.message : "request-failed",
	};
};
