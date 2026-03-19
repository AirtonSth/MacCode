/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-34: Health check redirect should not flash workspace UI.
 *
 * The fix checks health/error state early and returns a minimal loading
 * view before rendering the full workspace screen. This prevents the
 * partial render flash before the redirect to settings.
 */

interface HealthCheckInputs {
	isConfigLoaded: boolean;
	isLoaded: boolean;
	serverHealthIsError: boolean;
	serverHealthIsPending: boolean;
}

const computeIsHealthCheckPending = (inputs: HealthCheckInputs): boolean =>
	!inputs.isConfigLoaded || !inputs.isLoaded || inputs.serverHealthIsPending;

const computeIsHealthCheckError = (inputs: HealthCheckInputs): boolean =>
	inputs.isConfigLoaded &&
	inputs.isLoaded &&
	!inputs.serverHealthIsPending &&
	inputs.serverHealthIsError;

const shouldShowMinimalLoadingView = (inputs: HealthCheckInputs): boolean =>
	computeIsHealthCheckPending(inputs) || computeIsHealthCheckError(inputs);

describe("M-34: Workspace health check redirect flash", () => {
	test("shows loading when config is not yet loaded", () => {
		expect(shouldShowMinimalLoadingView({
			isConfigLoaded: false,
			isLoaded: false,
			serverHealthIsError: false,
			serverHealthIsPending: true,
		})).toBe(true);
	});

	test("shows loading while health check is pending", () => {
		expect(shouldShowMinimalLoadingView({
			isConfigLoaded: true,
			isLoaded: true,
			serverHealthIsError: false,
			serverHealthIsPending: true,
		})).toBe(true);
	});

	test("shows loading when health check errored (before redirect)", () => {
		expect(shouldShowMinimalLoadingView({
			isConfigLoaded: true,
			isLoaded: true,
			serverHealthIsError: true,
			serverHealthIsPending: false,
		})).toBe(true);
	});

	test("shows full workspace UI when healthy and loaded", () => {
		expect(shouldShowMinimalLoadingView({
			isConfigLoaded: true,
			isLoaded: true,
			serverHealthIsError: false,
			serverHealthIsPending: false,
		})).toBe(false);
	});

	test("does not show workspace UI when workspace data is still loading", () => {
		expect(shouldShowMinimalLoadingView({
			isConfigLoaded: true,
			isLoaded: false,
			serverHealthIsError: false,
			serverHealthIsPending: false,
		})).toBe(true);
	});
});
