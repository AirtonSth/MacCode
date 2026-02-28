import { useState } from "react";

type UseCounterProps = {
	initialValue?: number;
};

export type UseCounterResult = {
	count: number;
	increment: () => void;
	decrement: () => void;
	reset: () => void;
};

export function useCounter({ initialValue = 0 }: UseCounterProps = {}): UseCounterResult {
	const [count, setCount] = useState(initialValue);

	return {
		count,
		increment: () => setCount((value) => value + 1),
		decrement: () => setCount((value) => value - 1),
		reset: () => setCount(initialValue),
	};
}
