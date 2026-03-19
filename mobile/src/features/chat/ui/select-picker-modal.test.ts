/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "select-picker-modal.tsx"), "utf8");

describe("[M-46] select picker modal preserves scroll position", () => {
	it("stores per-picker scroll offsets in a ref map", () => {
		expect(source).toContain("const scrollOffsetsRef = useRef<Record<ActivePicker, number>>");
		expect(source).toContain("model: 0");
		expect(source).toContain("provider: 0");
		expect(source).toContain("reasoning: 0");
		expect(source).toContain("permission: 0");
	});

	it("updates the cached offset from the ScrollView onScroll handler", () => {
		expect(source).toContain("const handleScroll = useCallback(");
		expect(source).toContain("scrollOffsetsRef.current[props.activePicker] = event.nativeEvent.contentOffset.y;");
	});

	it("restores the cached offset when the modal opens again", () => {
		expect(source).toContain("restorePickerRef.current = props.activePicker;");
		expect(source).toContain("scrollViewRef.current?.scrollTo({");
		expect(source).toContain("animated: false");
		expect(source).toContain("y: scrollOffsetsRef.current[activePicker] ?? 0");
	});

	it("restores again after content size changes to avoid opening at the top", () => {
		expect(source).toContain("onContentSizeChange={restoreScrollPosition}");
	});
});
