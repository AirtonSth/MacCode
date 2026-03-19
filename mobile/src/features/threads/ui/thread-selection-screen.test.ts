/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * Tests for the isRedirectPending logic used in ThreadSelectionScreen (M-30).
 *
 * The derived boolean prevents the "No workspace selected" flash by returning
 * a loading state instead of the full screen when a redirect is imminent.
 */

interface RedirectInputs {
	isConfigLoaded: boolean;
	isLoaded: boolean;
	selectedProjectId: string | null;
	serverHealthIsError: boolean;
	serverHealthIsPending: boolean;
}

const computeIsRedirectPending = (inputs: RedirectInputs): boolean =>
	inputs.isConfigLoaded &&
	inputs.isLoaded &&
	!inputs.serverHealthIsPending &&
	(!inputs.selectedProjectId || inputs.serverHealthIsError);

describe("isRedirectPending (M-30)", () => {
	it("returns true when no project is selected and everything is loaded", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: true,
			isLoaded: true,
			selectedProjectId: null,
			serverHealthIsError: false,
			serverHealthIsPending: false,
		});

		expect(result).toBe(true);
	});

	it("returns true when server health is errored", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: true,
			isLoaded: true,
			selectedProjectId: "proj-1",
			serverHealthIsError: true,
			serverHealthIsPending: false,
		});

		expect(result).toBe(true);
	});

	it("returns false when a project is selected and server is healthy", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: true,
			isLoaded: true,
			selectedProjectId: "proj-1",
			serverHealthIsError: false,
			serverHealthIsPending: false,
		});

		expect(result).toBe(false);
	});

	it("returns false while config is still loading", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: false,
			isLoaded: true,
			selectedProjectId: null,
			serverHealthIsError: false,
			serverHealthIsPending: false,
		});

		expect(result).toBe(false);
	});

	it("returns false while shell is still loading", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: true,
			isLoaded: false,
			selectedProjectId: null,
			serverHealthIsError: false,
			serverHealthIsPending: false,
		});

		expect(result).toBe(false);
	});

	it("returns false while server health query is pending", () => {
		const result = computeIsRedirectPending({
			isConfigLoaded: true,
			isLoaded: true,
			selectedProjectId: null,
			serverHealthIsError: false,
			serverHealthIsPending: true,
		});

		expect(result).toBe(false);
	});
});
