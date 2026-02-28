import { CounterFeature } from "../features/counter";

function App(): JSX.Element {
	return (
		<div className="app-shell">
			<main>
				<header className="app-header">
					<h1>Electrobun + React</h1>
					<p>Arquitetura orientada a features</p>
				</header>
				<CounterFeature />
			</main>
	</div>
	);
}

export default App;
