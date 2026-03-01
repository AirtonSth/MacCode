const ELECTROBUN_DRAG_REGION_SELECTOR = ".electrobun-webkit-app-region-drag";
const ELECTROBUN_STOP_WINDOW_MOVE_EVENT_ID = "stopWindowMove";

type ElectrobunBridge = {
	postMessage: (payload: string) => void;
};

type ElectrobunRuntimeWindow = Window & {
	__electrobunInternalBridge?: ElectrobunBridge;
	__electrobunWindowId?: string | number;
};

export const isElectrobunDragRegionTarget = (
	target: EventTarget | null,
	selector = ELECTROBUN_DRAG_REGION_SELECTOR,
): boolean => {
	if (!target || typeof target !== "object") {
		return false;
	}

	const elementLike = target as { closest?: (input: string) => Element | null };
	if (typeof elementLike.closest !== "function") {
		return false;
	}

	return Boolean(elementLike.closest(selector));
};

export const serializeElectrobunBridgeMessage = (
	messageId: string,
	windowId: string | number,
): string => {
	return JSON.stringify([
		JSON.stringify({
			type: "message",
			id: messageId,
			payload: {
				id: windowId,
			},
		}),
	]);
};

export const postStopWindowMove = (runtimeWindow: ElectrobunRuntimeWindow): boolean => {
	const bridge = runtimeWindow.__electrobunInternalBridge;
	const windowId = runtimeWindow.__electrobunWindowId;

	if (!bridge || typeof bridge.postMessage !== "function") {
		return false;
	}

	if (typeof windowId !== "string" && typeof windowId !== "number") {
		return false;
	}

	bridge.postMessage(
		serializeElectrobunBridgeMessage(ELECTROBUN_STOP_WINDOW_MOVE_EVENT_ID, windowId),
	);

	return true;
};

interface DragRegionSafetyControllerConfig {
	isDragRegionTarget: (target: EventTarget | null) => boolean;
	onStopWindowMove: () => void;
}

export interface DragRegionSafetyController {
	handleMouseDown: (target: EventTarget | null) => void;
	handleMouseUp: () => void;
	handleBlur: () => void;
	handleDocumentVisibilityChange: (isHidden: boolean) => void;
	isDragGestureActive: () => boolean;
}

export const createDragRegionSafetyController = (
	config: DragRegionSafetyControllerConfig,
): DragRegionSafetyController => {
	let dragGestureActive = false;

	const stopDragGesture = () => {
		if (!dragGestureActive) {
			return;
		}

		dragGestureActive = false;
		config.onStopWindowMove();
	};

	return {
		handleMouseDown: (target) => {
			const dragRegionTarget = config.isDragRegionTarget(target);
			if (!dragRegionTarget && dragGestureActive) {
				dragGestureActive = false;
				config.onStopWindowMove();
			}

			dragGestureActive = dragRegionTarget;
		},
		handleMouseUp: stopDragGesture,
		handleBlur: stopDragGesture,
		handleDocumentVisibilityChange: (isHidden) => {
			if (isHidden) {
				stopDragGesture();
			}
		},
		isDragGestureActive: () => dragGestureActive,
	};
};

export const installElectrobunDragRegionSafetyGuard = (
	runtimeWindow: ElectrobunRuntimeWindow,
	runtimeDocument: Document,
): (() => void) => {
	const controller = createDragRegionSafetyController({
		isDragRegionTarget: (target) => isElectrobunDragRegionTarget(target),
		onStopWindowMove: () => {
			void postStopWindowMove(runtimeWindow);
		},
	});

	const onMouseDown = (event: MouseEvent) => {
		controller.handleMouseDown(event.target);
	};

	const onMouseUp = () => {
		controller.handleMouseUp();
	};

	const onBlur = () => {
		controller.handleBlur();
	};

	const onVisibilityChange = () => {
		controller.handleDocumentVisibilityChange(runtimeDocument.visibilityState === "hidden");
	};

	runtimeDocument.addEventListener("mousedown", onMouseDown, true);
	runtimeWindow.addEventListener("mouseup", onMouseUp, true);
	runtimeWindow.addEventListener("blur", onBlur);
	runtimeDocument.addEventListener("visibilitychange", onVisibilityChange);

	return () => {
		runtimeDocument.removeEventListener("mousedown", onMouseDown, true);
		runtimeWindow.removeEventListener("mouseup", onMouseUp, true);
		runtimeWindow.removeEventListener("blur", onBlur);
		runtimeDocument.removeEventListener("visibilitychange", onVisibilityChange);
	};
};
