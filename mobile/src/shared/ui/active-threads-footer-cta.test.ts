/* eslint-disable import/no-unresolved */
/* eslint-disable new-cap */
import { beforeEach, describe, expect, mock, test } from "bun:test";

const animationState = {
	timingCalls: [] as { toValue: number; duration: number }[],
	startCalls: 0,
};

const resetAnimationState = () => {
	animationState.timingCalls = [];
	animationState.startCalls = 0;
};

const stubCompositeAnimation = () => ({
	start: () => {
		animationState.startCalls += 1;
	},
	stop: () => undefined,
});

const noop = () => null;

let latestAnimatedValue = 0;

mock.module("react-native", () => ({
	ActivityIndicator: "ActivityIndicator",
	Animated: {
		Value: class AnimatedValue {
			public value: number;

			public constructor(v: number) {
				this.value = v;
				latestAnimatedValue = v;
			}
		},
		View: "div",
		timing: (animValue: { value: number }, config: { toValue: number; duration: number; useNativeDriver: boolean }) => {
			animationState.timingCalls.push({ toValue: config.toValue, duration: config.duration });
			return stubCompositeAnimation();
		},
	},
	Pressable: "Pressable",
	StyleSheet: {
		create: <T extends Record<string, unknown>>(styles: T): T => styles,
	},
	Text: "Text",
	View: "View",
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

const { ActiveThreadsFooterCta } = await import("./active-threads-footer-cta");

beforeEach(() => {
	resetAnimationState();
	useRefStore = [];
	useRefIndex = 0;
	latestAnimatedValue = 0;
});

describe("ActiveThreadsFooterCta", () => {
	test("always renders (no null return) so fade-out animation can play", () => {
		ActiveThreadsFooterCta({
			count: 0,
			onPress: () => undefined,
			testID: "test-cta",
		});

		// The component always renders to allow fade-out animation.
		// We verify by checking that the animation effect ran and targeted opacity 0.
		expect(animationState.timingCalls.length).toBe(1);
		expect(animationState.timingCalls[0].toValue).toBe(0);
	});

	test("renders visible when count > 0 and animates to opacity 1", () => {
		ActiveThreadsFooterCta({
			count: 3,
			onPress: () => undefined,
			testID: "test-cta",
		});

		expect(animationState.timingCalls.length).toBe(1);
		expect(animationState.timingCalls[0].toValue).toBe(1);
		expect(animationState.startCalls).toBe(1);
	});

	test("animation starts from opacity 0", () => {
		ActiveThreadsFooterCta({
			count: 5,
			onPress: () => undefined,
			testID: "test-cta",
		});

		// The Animated.Value is initialized with 0 in the component
		expect(latestAnimatedValue).toBe(0);
	});

	test("stays hidden when count is 0", () => {
		ActiveThreadsFooterCta({
			count: 0,
			onPress: () => undefined,
			testID: "test-cta",
		});

		expect(animationState.timingCalls.length).toBe(1);
		expect(animationState.timingCalls[0].toValue).toBe(0);
	});

	test("fade animation uses 200ms duration", () => {
		ActiveThreadsFooterCta({
			count: 2,
			onPress: () => undefined,
			testID: "test-cta",
		});

		expect(animationState.timingCalls[0].duration).toBe(200);
	});
});
