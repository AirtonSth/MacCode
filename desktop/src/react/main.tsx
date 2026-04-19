import "./index.css";

import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import App from "./app";

const hideSplash = () => {
	const splash = document.querySelector<HTMLDivElement>("#initial-splash");
	if (!splash) {
		return;
	}
	splash.dataset.hide = "true";
	window.setTimeout(() => {
		splash.remove();
	}, 200);
};

createRoot(document.querySelector("#root")!).render(
	<StrictMode>
		<App />
	</StrictMode>,
);

if (typeof window !== "undefined") {
	if (document.readyState === "complete") {
		window.requestAnimationFrame(hideSplash);
	} else {
		window.addEventListener("load", () => window.requestAnimationFrame(hideSplash), { once: true });
	}
}
