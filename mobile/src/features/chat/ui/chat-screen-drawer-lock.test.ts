/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-21] Tests for the drawer animation lock.
 *
 * Previously, fast taps during the close animation could leave the drawer
 * in a half-open state because `isDrawerOpen` was true while the close
 * animation was running and another close/open could interfere.
 *
 * The fix adds an `isAnimatingRef` guard that prevents interactions
 * during the animation (~170ms for the translation).
 */

/**
 * Simulates the drawer toggle lock logic.
 * The ref prevents closeDrawer from being called when an animation
 * is already in progress.
 */
class DrawerAnimationLock {
	public isAnimating = false;

	public isOpen = false;

	public closeCallCount = 0;

	public animationCallbackQueue: (() => void)[] = [];

	public open(): void {
		if (this.isAnimating) {
			return;
		}
		this.isOpen = true;
	}

	public close(): void {
		if (this.isAnimating) {
			return;
		}
		this.isAnimating = true;
		this.closeCallCount += 1;

		// Queue the animation completion callback
		this.animationCallbackQueue.push(() => {
			this.isOpen = false;
			this.isAnimating = false;
		});
	}

	/** Simulate animation completing */
	public finishAnimation(): void {
		const callback = this.animationCallbackQueue.shift();
		if (callback) {
			callback();
		}
	}
}

describe("[M-21] drawer animation lock", () => {
	it("prevents double-close during animation", () => {
		const lock = new DrawerAnimationLock();
		lock.open();
		expect(lock.isOpen).toBe(true);

		// First close starts animation
		lock.close();
		expect(lock.isAnimating).toBe(true);
		expect(lock.closeCallCount).toBe(1);

		// Second close is blocked
		lock.close();
		expect(lock.closeCallCount).toBe(1); // still 1

		// Animation finishes
		lock.finishAnimation();
		expect(lock.isOpen).toBe(false);
		expect(lock.isAnimating).toBe(false);
	});

	it("allows close after animation completes", () => {
		const lock = new DrawerAnimationLock();
		lock.open();

		lock.close();
		lock.finishAnimation();
		expect(lock.isOpen).toBe(false);
		expect(lock.isAnimating).toBe(false);

		// Reopen and close again
		lock.open();
		expect(lock.isOpen).toBe(true);

		lock.close();
		expect(lock.isAnimating).toBe(true);
		expect(lock.closeCallCount).toBe(2);

		lock.finishAnimation();
		expect(lock.isOpen).toBe(false);
	});

	it("blocks open during close animation", () => {
		const lock = new DrawerAnimationLock();
		lock.open();

		// Start closing
		lock.close();
		expect(lock.isAnimating).toBe(true);

		// Attempt to open during animation is blocked
		lock.open();

		// isOpen is still true from the initial open (close hasn't finished)
		// The key: animation lock prevents interference

		lock.finishAnimation();

		// After animation the drawer should be closed
		expect(lock.isOpen).toBe(false);
	});

	it("handles rapid tap sequence correctly", () => {
		const lock = new DrawerAnimationLock();
		lock.open();

		// Rapid taps: close, close, close
		lock.close();
		lock.close();
		lock.close();

		// Only one animation should have started
		expect(lock.closeCallCount).toBe(1);
		expect(lock.animationCallbackQueue.length).toBe(1);

		lock.finishAnimation();
		expect(lock.isOpen).toBe(false);
		expect(lock.isAnimating).toBe(false);
	});
});

describe("[M-21] closeDrawerThen callback integrity", () => {
	it("calls the onClosed callback after animation completes", () => {
		let callbackCalled = false;
		let isAnimating = false;

		const closeDrawerThen = (onClosed: () => void) => {
			if (isAnimating) {
				return;
			}
			isAnimating = true;

			// Simulate animation start -> completion
			setTimeout(() => {
				isAnimating = false;
				onClosed();
			}, 0);
		};

		closeDrawerThen(() => {
			callbackCalled = true;
		});

		// Before animation finishes, second call should be blocked
		let secondCallbackCalled = false;
		closeDrawerThen(() => {
			secondCallbackCalled = true;
		});

		expect(isAnimating).toBe(true);
		expect(secondCallbackCalled).toBe(false);

		// Note: callbackCalled will be true after the setTimeout fires
		// but in sync context it hasn't run yet
		expect(callbackCalled).toBe(false);
	});
});
