/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { createPointerRef, type Pointer } from "./ChatEmptyBackground";

test("pointerRef identity stays stable across mutations (no re-renders)", () => {
	const ref = createPointerRef();
	const initialCurrent = ref.current;

	// Simulate many pointermove updates — the ref object itself must never change identity.
	for (let i = 0; i < 200; i++) {
		ref.current.horizontal = (i / 200 - 0.5) * 2;
		ref.current.vertical = ((200 - i) / 200 - 0.5) * -2;
	}

	// The exact same object reference must persist — React will not re-render
	// because mutating a ref does not trigger the reconciler.
	expect(ref.current).toBe(initialCurrent);
});

test("pointerRef holds correct values after mutation", () => {
	const ref = createPointerRef();

	ref.current.horizontal = 0.75;
	ref.current.vertical = -0.33;

	expect(ref.current.horizontal).toBe(0.75);
	expect(ref.current.vertical).toBe(-0.33);
});

test("createPointerRef returns zeroed pointer by default", () => {
	const ref = createPointerRef();
	const pointer: Pointer = ref.current;

	expect(pointer.horizontal).toBe(0);
	expect(pointer.vertical).toBe(0);
});
