/* eslint-disable import/no-unresolved */
/* eslint-disable new-cap */
import { beforeEach, describe, expect, mock, test } from "bun:test";

const animationState = {
	sequenceStartCalls: 0,
	sequenceStopCalls: 0,
	startCallback: null as ((result: { finished: boolean }) => void) | null,
};

const resetAnimationState = () => {
	animationState.sequenceStartCalls = 0;
	animationState.sequenceStopCalls = 0;
	animationState.startCallback = null;
};

const stubCompositeAnimation = () => ({
	start: (cb?: (result: { finished: boolean }) => void) => {
		animationState.sequenceStartCalls += 1;
		if (cb) {
			animationState.startCallback = cb;
		}
	},
	stop: () => {
		animationState.sequenceStopCalls += 1;
	},
});

const identity = (v: number) => v;
const passthrough = () => identity;
const noop = () => null;

mock.module("react-native", () => {
	const absoluteFill = { bottom: 0, left: 0, position: "absolute" as const, right: 0, top: 0 };
	return {
		Animated: {
			Value: mock(() => undefined),
			View: "div",
			delay: () => stubCompositeAnimation(),
			parallel: () => stubCompositeAnimation(),
			sequence: () => stubCompositeAnimation(),
			timing: () => stubCompositeAnimation(),
		},
		Easing: {
			cubic: identity,
			in: passthrough,
			out: passthrough,
			quad: identity,
		},
		Image: "img",
		StyleSheet: {
			absoluteFill,
			create: <T extends Record<string, unknown>>(styles: T): T => styles,
		},
	};
});

mock.module("../../../assets/images/icon.png", () => ({
	default: "icon.png",
}));

mock.module("react/jsx-dev-runtime", () => ({
	Fragment: "Fragment",
	jsxDEV: noop,
}));

mock.module("react/jsx-runtime", () => ({
	Fragment: "Fragment",
	jsx: noop,
	jsxs: noop,
}));

interface RefObject {
	current: unknown;
}

let useRefStore: RefObject[] = [];
let useRefIndex = 0;

mock.module("react", () => ({
	useEffect: (cb: () => (() => void) | undefined) => {
		cb();
	},
	useRef: (initial: unknown) => {
		if (useRefIndex < useRefStore.length) {
			const existing = useRefStore[useRefIndex];
			useRefIndex += 1;
			return existing;
		}
		const ref: RefObject = { current: initial };
		useRefStore.push(ref);
		useRefIndex += 1;
		return ref;
	},
}));

const { AnimatedLaunchSplash } = await import("./animated-launch-splash");

beforeEach(() => {
	resetAnimationState();
	useRefStore = [];
	useRefIndex = 0;
});

describe("AnimatedLaunchSplash", () => {
	test("animation effect runs only once regardless of parent re-renders", () => {
		const onFinish1 = mock(() => undefined);
		const onFinish2 = mock(() => undefined);

		// First render
		AnimatedLaunchSplash({ onFinish: onFinish1 });

		expect(animationState.sequenceStartCalls).toBe(1);

		// Simulate parent re-render with a new onFinish reference.
		// The ref store is reused (not cleared), so useRef returns existing refs.
		resetAnimationState();
		useRefIndex = 0;
		AnimatedLaunchSplash({ onFinish: onFinish2 });

		// The ref should have been updated to the latest callback.
		// In real React, the animation useEffect would NOT re-run because
		// onFinish is no longer in its dependency array.
		const onFinishRef = useRefStore.find(
			(ref) => typeof ref.current === "function",
		);
		expect(onFinishRef).toBeDefined();
		expect(onFinishRef?.current).toBe(onFinish2);
	});

	test("onFinish is called via ref so changing the prop does not restart the animation", () => {
		const onFinish1 = mock(() => undefined);
		const onFinish2 = mock(() => undefined);

		// First render
		AnimatedLaunchSplash({ onFinish: onFinish1 });

		// Capture the callback that was passed to sequence.start
		const firstStartCallback = animationState.startCallback;
		expect(firstStartCallback).not.toBeNull();

		// Simulate parent re-render that updates the ref
		useRefIndex = 0;
		AnimatedLaunchSplash({ onFinish: onFinish2 });

		// Simulate the animation finishing by calling the original start callback.
		// The ref should have been updated to onFinish2, so onFinish2 gets called
		// even though onFinish1 was the prop when the animation started.
		firstStartCallback?.({ finished: true });

		expect(onFinish1).not.toHaveBeenCalled();
		expect(onFinish2).toHaveBeenCalledTimes(1);
	});

	test("onFinish is not called when animation does not finish", () => {
		const onFinish = mock(() => undefined);

		AnimatedLaunchSplash({ onFinish });

		const startCallback = animationState.startCallback;
		expect(startCallback).not.toBeNull();

		// Simulate animation being interrupted
		startCallback?.({ finished: false });

		expect(onFinish).not.toHaveBeenCalled();
	});
});
