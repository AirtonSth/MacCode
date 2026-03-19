/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-39] Tests for keyboard listener cleanup on fast unmount.
 *
 * Previously, keyboard listeners (keyboardDidShow / keyboardDidHide)
 * were registered once in a useEffect with an empty dependency array.
 * When the user navigated away quickly, the screen could lose focus
 * while listeners persisted, causing state updates on an unfocused
 * screen.
 *
 * The fix adds `isFocused` to the useEffect dependency array so that
 * listeners are removed when the screen loses focus and re-added
 * when it regains focus. The cleanup function always removes both
 * subscriptions.
 */

interface KeyboardSubscription {
	remove: () => void;
}

/**
 * Simulates the keyboard listener lifecycle with focus awareness.
 * Mirrors the pattern in chat-screen.tsx useEffect with isFocused.
 */
class KeyboardListenerManager {
	public activeSubscriptions: KeyboardSubscription[] = [];

	public removedCount = 0;

	public showCallCount = 0;

	public hideCallCount = 0;

	private cleanupFn: (() => void) | null = null;

	/**
	 * Simulates the useEffect being called when isFocused changes.
	 * Returns the cleanup function for the previous effect run.
	 */
	public runEffect(isFocused: boolean): void {
		// First, run cleanup from previous effect
		if (this.cleanupFn) {
			this.cleanupFn();
			this.cleanupFn = null;
		}

		if (!isFocused) {
			this.cleanupFn = () => {
				// intentional
			};
			return;
		}

		const showSub: KeyboardSubscription = {
			remove: () => {
				this.removedCount += 1;
			},
		};
		const hideSub: KeyboardSubscription = {
			remove: () => {
				this.removedCount += 1;
			},
		};

		this.activeSubscriptions.push(showSub, hideSub);

		this.cleanupFn = () => {
			showSub.remove();
			hideSub.remove();
		};
	}

	/** Simulates the final cleanup (component unmount). */
	public unmount(): void {
		if (this.cleanupFn) {
			this.cleanupFn();
			this.cleanupFn = null;
		}
	}
}

describe("[M-39] keyboard listener focus-aware lifecycle", () => {
	it("registers listeners when focused", () => {
		const manager = new KeyboardListenerManager();
		manager.runEffect(true);
		expect(manager.activeSubscriptions.length).toBe(2);
		expect(manager.removedCount).toBe(0);
	});

	it("does not register listeners when not focused", () => {
		const manager = new KeyboardListenerManager();
		manager.runEffect(false);
		expect(manager.activeSubscriptions.length).toBe(0);
		expect(manager.removedCount).toBe(0);
	});

	it("removes listeners when focus is lost", () => {
		const manager = new KeyboardListenerManager();

		// Screen gains focus
		manager.runEffect(true);
		expect(manager.activeSubscriptions.length).toBe(2);

		// Screen loses focus — cleanup runs, removing both listeners
		manager.runEffect(false);
		expect(manager.removedCount).toBe(2);
	});

	it("re-registers listeners when focus is regained", () => {
		const manager = new KeyboardListenerManager();

		// Focus -> unfocus -> focus
		manager.runEffect(true);
		manager.runEffect(false);
		expect(manager.removedCount).toBe(2);

		manager.runEffect(true);

		// 2 original + 2 new = 4 total subscriptions created
		expect(manager.activeSubscriptions.length).toBe(4);
	});

	it("cleans up on unmount while focused", () => {
		const manager = new KeyboardListenerManager();
		manager.runEffect(true);
		expect(manager.removedCount).toBe(0);

		manager.unmount();
		expect(manager.removedCount).toBe(2);
	});

	it("cleans up on unmount while not focused", () => {
		const manager = new KeyboardListenerManager();
		manager.runEffect(true);
		manager.runEffect(false);

		const removedBeforeUnmount = manager.removedCount;
		manager.unmount();

		// The unfocused cleanup is a no-op, so no additional removes
		expect(manager.removedCount).toBe(removedBeforeUnmount);
	});
});

describe("[M-39] rapid navigation does not leave orphan listeners", () => {
	it("handles rapid focus/unfocus transitions without leaking", () => {
		const manager = new KeyboardListenerManager();

		// Simulate rapid navigation: focus, unfocus, focus, unfocus
		manager.runEffect(true);
		manager.runEffect(false);
		manager.runEffect(true);
		manager.runEffect(false);

		// Each focus cycle registers 2, each unfocus removes 2
		// Total subscriptions created: 4 (2 per focus)
		// Total removed: 4 (2 per unfocus)
		expect(manager.activeSubscriptions.length).toBe(4);
		expect(manager.removedCount).toBe(4);
	});

	it("final unmount after rapid navigation has no orphan listeners", () => {
		const manager = new KeyboardListenerManager();

		manager.runEffect(true);
		manager.runEffect(false);
		manager.runEffect(true);

		// Currently focused — 2 active listeners from last focus
		// Unmount should clean them up
		manager.unmount();

		// 2 from first unfocus + 2 from unmount = 4
		expect(manager.removedCount).toBe(4);
	});
});
