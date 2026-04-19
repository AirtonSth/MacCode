import { useEffect, useRef } from "react";

export interface GlobalKeybindings {
	onOpenPalette?: () => void;
	onToggleSidebar?: () => void;
	onStopStreaming?: () => void;
	onFocusComposer?: () => void;
	onOpenHistorySearch?: () => void;
	onNewChat?: () => void;
	onCycleProvider?: () => void;
}

const isEditableTarget = (target: EventTarget | null): boolean => {
	if (!(target instanceof HTMLElement)) {
		return false;
	}
	const tag = target.tagName;
	if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
		return true;
	}
	return target.isContentEditable;
};

export function useGlobalKeybindings(handlers: GlobalKeybindings): void {
	const ref = useRef(handlers);
	ref.current = handlers;

	useEffect(() => {
		const handleKeyDown = (event: KeyboardEvent) => {
			const h = ref.current;
			const modifier = event.metaKey || event.ctrlKey;

			if (modifier && event.key.toLowerCase() === "k" && !event.shiftKey && !event.altKey) {
				event.preventDefault();
				h.onOpenPalette?.();
				return;
			}

			if (modifier && event.key.toLowerCase() === "b" && !event.shiftKey && !event.altKey) {
				event.preventDefault();
				h.onToggleSidebar?.();
				return;
			}

			if (modifier && event.key.toLowerCase() === "r" && !event.shiftKey && !event.altKey) {
				event.preventDefault();
				h.onOpenHistorySearch?.();
				return;
			}

			if (modifier && event.key.toLowerCase() === "n" && !event.shiftKey && !event.altKey) {
				event.preventDefault();
				h.onNewChat?.();
				return;
			}

			if (
				modifier &&
				event.shiftKey &&
				event.key === "P" &&
				!event.altKey
			) {
				event.preventDefault();
				h.onCycleProvider?.();
				return;
			}

			if (event.key === "Escape" && !isEditableTarget(event.target)) {
				h.onStopStreaming?.();
				return;
			}

			if (event.key === "/" && !isEditableTarget(event.target) && !modifier) {
				event.preventDefault();
				h.onFocusComposer?.();
			}
		};

		window.addEventListener("keydown", handleKeyDown);
		return () => {
			window.removeEventListener("keydown", handleKeyDown);
		};
	}, []);
}
