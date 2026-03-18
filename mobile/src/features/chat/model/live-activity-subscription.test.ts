/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import { RemoteCodeRequestError } from "../../../shared/api/remotecode-client";
import {
	resolveLiveActivitySubscriptionError,
	resolveLiveActivitySubscriptionResponse,
} from "./live-activity-subscription";

describe("live activity subscription decisions", () => {
	test("keeps the activity local-only when backend support is disabled", () => {
		expect(resolveLiveActivitySubscriptionResponse({
			enabled: false,
			subscribed: false,
		})).toEqual({
			kind: "local-only",
			reason: "disabled",
		});
	});

	test("retries when the backend is enabled but has not accepted the subscription yet", () => {
		expect(resolveLiveActivitySubscriptionResponse({
			enabled: true,
			subscribed: false,
		})).toEqual({
			kind: "retry",
			reason: "subscription-not-accepted",
		});
	});

	test("clears only when the chat no longer exists", () => {
		expect(resolveLiveActivitySubscriptionError(
			new RemoteCodeRequestError(404, "chat not found"),
		)).toEqual({
			kind: "clear",
			reason: "chat-not-found",
		});
	});

	test("keeps the activity local-only for other permanent subscription failures", () => {
		expect(resolveLiveActivitySubscriptionError(
			new RemoteCodeRequestError(400, "invalid live activity subscription payload"),
		)).toEqual({
			kind: "local-only",
			reason: "request-400",
		});
		expect(resolveLiveActivitySubscriptionError(
			new RemoteCodeRequestError(404, "subscription route unavailable"),
		)).toEqual({
			kind: "local-only",
			reason: "request-404",
		});
	});
});
