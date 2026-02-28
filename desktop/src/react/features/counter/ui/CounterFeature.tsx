import { useCounter } from "../hooks/useCounter";

export function CounterFeature(): JSX.Element {
	const { count, decrement, increment, reset } = useCounter();

	return (
		<section className="feature feature--counter">
			<div className="card">
				<h2>Contador</h2>
				<p className="value">Valor atual: {count}</p>
				<div className="actions">
					<button type="button" onClick={increment}>
						+1
					</button>
					<button type="button" onClick={decrement}>
						-1
					</button>
					<button type="button" onClick={reset}>
						Reset
					</button>
				</div>
			</div>
		</section>
	);
}
