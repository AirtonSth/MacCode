import { useCallback,useState } from "react";

export interface UseCounterResult {
	count: number;
	decrement: () => void;
	increment: () => void;
	reset: () => void;
}

interface UseCounterProps {
	initialValue?: number;
}

export function useCounter({ initialValue = 0 }: UseCounterProps = {}): UseCounterResult {
	const [count, setCount] = useState(initialValue);

	return {
		count,
		decrement: useCallback(() => { setCount((value) => value - 1); }, []),
		increment: useCallback(() => { setCount((value) => value + 1); }, []),
		reset: useCallback(() => { setCount(initialValue); }, []),
	};
}
