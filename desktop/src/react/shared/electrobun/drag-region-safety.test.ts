import { expect, test } from "bun:test";

import {
	createDragRegionSafetyController,
	installElectrobunDragRegionSafetyGuard,
	isElectrobunDragRegionTarget,
	postStopWindowMove,
	serializeElectrobunBridgeMessage,
} from "./drag-region-safety";

test("isElectrobunDragRegionTarget returns true only when closest drag region exists", () => {
	const dragTarget = {
		closest: (selector: string) => {
			return selector === ".electrobun-webkit-app-region-drag" ? ({} as Element) : null;
		},
	};
	const neutralTarget = {
		closest: () => null,
	};

	expect(isElectrobunDragRegionTarget(dragTarget as unknown as EventTarget)).toBe(true);
	expect(isElectrobunDragRegionTarget(neutralTarget as unknown as EventTarget)).toBe(false);
	expect(isElectrobunDragRegionTarget(null)).toBe(false);
});

test("serializeElectrobunBridgeMessage creates bridge-compatible payload", () => {
	expect(serializeElectrobunBridgeMessage("stopWindowMove", "window-42")).toBe(
		JSON.stringify([
			JSON.stringify({
				type: "message",
				id: "stopWindowMove",
				payload: {
					id: "window-42",
				},
			}),
		]),
	);
});

test("postStopWindowMove sends stop payload when bridge and window id are available", () => {
	const payloads: string[] = [];
	const runtimeWindow = {
		__electrobunInternalBridge: {
			postMessage: (payload: string) => {
				payloads.push(payload);
			},
		},
		__electrobunWindowId: "window-7",
	} as unknown as Window & {
		__electrobunInternalBridge?: { postMessage: (payload: string) => void };
		__electrobunWindowId?: string | number;
	};

	const posted = postStopWindowMove(runtimeWindow);

	expect(posted).toBe(true);
	expect(payloads).toEqual([serializeElectrobunBridgeMessage("stopWindowMove", "window-7")]);
});

test("drag safety controller releases drag on mouseup outside drag region", () => {
	let stopCalls = 0;
	const dragTarget = { id: "drag" } as unknown as EventTarget;
	const controller = createDragRegionSafetyController({
		isDragRegionTarget: (target) => target === dragTarget,
		onStopWindowMove: () => {
			stopCalls += 1;
		},
	});

	controller.handleMouseDown(dragTarget);
	expect(controller.isDragGestureActive()).toBe(true);

	controller.handleMouseUp();
	expect(controller.isDragGestureActive()).toBe(false);
	expect(stopCalls).toBe(1);
});

test("drag safety controller releases stale drag when next mousedown is outside drag region", () => {
	let stopCalls = 0;
	const dragTarget = { id: "drag" } as unknown as EventTarget;
	const nonDragTarget = { id: "content" } as unknown as EventTarget;
	const controller = createDragRegionSafetyController({
		isDragRegionTarget: (target) => target === dragTarget,
		onStopWindowMove: () => {
			stopCalls += 1;
		},
	});

	controller.handleMouseDown(dragTarget);
	expect(controller.isDragGestureActive()).toBe(true);

	controller.handleMouseDown(nonDragTarget);
	expect(controller.isDragGestureActive()).toBe(false);
	expect(stopCalls).toBe(1);
});

test("drag safety controller releases drag on blur and document hidden", () => {
	let stopCalls = 0;
	const dragTarget = { id: "drag" } as unknown as EventTarget;
	const controller = createDragRegionSafetyController({
		isDragRegionTarget: (target) => target === dragTarget,
		onStopWindowMove: () => {
			stopCalls += 1;
		},
	});

	controller.handleMouseDown(dragTarget);
	controller.handleBlur();
	expect(stopCalls).toBe(1);
	expect(controller.isDragGestureActive()).toBe(false);

	controller.handleMouseDown(dragTarget);
	controller.handleDocumentVisibilityChange(true);
	expect(stopCalls).toBe(2);
	expect(controller.isDragGestureActive()).toBe(false);
});

test("installElectrobunDragRegionSafetyGuard posts stop when mouseup happens after drag mousedown", () => {
	const documentListeners = new Map<string, Set<(event: Event) => void>>();
	const windowListeners = new Map<string, Set<(event: Event) => void>>();
	const payloads: string[] = [];

	const runtimeDocument = {
		visibilityState: "visible",
		addEventListener: (type: string, listener: (event: Event) => void) => {
			const listeners = documentListeners.get(type) ?? new Set<(event: Event) => void>();
			listeners.add(listener);
			documentListeners.set(type, listeners);
		},
		removeEventListener: (type: string, listener: (event: Event) => void) => {
			documentListeners.get(type)?.delete(listener);
		},
	} as unknown as Document;

	const runtimeWindow = {
		__electrobunInternalBridge: {
			postMessage: (payload: string) => {
				payloads.push(payload);
			},
		},
		__electrobunWindowId: "window-88",
		addEventListener: (type: string, listener: (event: Event) => void) => {
			const listeners = windowListeners.get(type) ?? new Set<(event: Event) => void>();
			listeners.add(listener);
			windowListeners.set(type, listeners);
		},
		removeEventListener: (type: string, listener: (event: Event) => void) => {
			windowListeners.get(type)?.delete(listener);
		},
	} as unknown as Window & {
		__electrobunInternalBridge?: { postMessage: (payload: string) => void };
		__electrobunWindowId?: string | number;
	};

	const cleanup = installElectrobunDragRegionSafetyGuard(runtimeWindow, runtimeDocument);

	const dragTarget = {
		closest: (selector: string) => {
			return selector === ".electrobun-webkit-app-region-drag" ? ({} as Element) : null;
		},
	};

	for (const listener of documentListeners.get("mousedown") ?? []) {
		listener({ target: dragTarget } as unknown as Event);
	}

	for (const listener of windowListeners.get("mouseup") ?? []) {
		listener(new Event("mouseup"));
	}

	expect(payloads).toEqual([serializeElectrobunBridgeMessage("stopWindowMove", "window-88")]);

	cleanup();
});
