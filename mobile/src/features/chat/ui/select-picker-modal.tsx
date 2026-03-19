import { memo, useCallback, useEffect, useRef } from "react";
import {
	Modal,
	type NativeScrollEvent,
	type NativeSyntheticEvent,
	Pressable,
	ScrollView,
	Text,
} from "react-native";

import { chatScreenStyles } from "./chat-screen-styles";

type ActivePicker = "provider" | "model" | "permission" | "reasoning";

const getSelectModalTitle = (activePicker: ActivePicker | null): string => {
	switch (activePicker) {
		case "model": {
			return "Select model";
		}
		case "permission": {
			return "Select permission";
		}
		case "provider": {
			return "Select provider";
		}
		case "reasoning": {
			return "Select reasoning";
		}
		default: {
			return "Select option";
		}
	}
};

export interface SelectPickerModalProps {
	activePicker: ActivePicker | null;
	onClose: () => void;
	options: JSX.Element[];
}

// eslint-disable-next-line total-functions/no-unsafe-readonly-mutable-assignment
export const SelectPickerModal = memo(function SelectPickerModal(props: SelectPickerModalProps) {
	const scrollViewRef = useRef<ScrollView | null>(null);
	const restorePickerRef = useRef<ActivePicker | null>(null);
	const restoreRafRef = useRef<number | null>(null);
	const scrollOffsetsRef = useRef<Record<ActivePicker, number>>({
		model: 0,
		permission: 0,
		provider: 0,
		reasoning: 0,
	});

	const restoreScrollPosition = useCallback(() => {
		const activePicker = restorePickerRef.current;
		if (!activePicker) {
			return;
		}

		restorePickerRef.current = null;
		scrollViewRef.current?.scrollTo({
			animated: false,
			y: scrollOffsetsRef.current[activePicker] ?? 0,
		});
	}, []);

	useEffect(() => {
		if (!props.activePicker) {
			restorePickerRef.current = null;
			if (restoreRafRef.current !== null) {
				cancelAnimationFrame(restoreRafRef.current);
				restoreRafRef.current = null;
			}
			return undefined;
		}

		restorePickerRef.current = props.activePicker;
		if (restoreRafRef.current !== null) {
			cancelAnimationFrame(restoreRafRef.current);
		}
		restoreRafRef.current = requestAnimationFrame(() => {
			restoreRafRef.current = null;
			restoreScrollPosition();
		});

		return () => {
			if (restoreRafRef.current !== null) {
				cancelAnimationFrame(restoreRafRef.current);
				restoreRafRef.current = null;
			}
		};
	}, [props.activePicker, props.options.length, restoreScrollPosition]);

	useEffect(() => {
		return () => {
			if (restoreRafRef.current !== null) {
				cancelAnimationFrame(restoreRafRef.current);
				restoreRafRef.current = null;
			}
		};
	}, []);

	const handleScroll = useCallback(
		(event: NativeSyntheticEvent<NativeScrollEvent>) => {
			if (!props.activePicker) {
				return;
			}

			scrollOffsetsRef.current[props.activePicker] = event.nativeEvent.contentOffset.y;
		},
		[props.activePicker],
	);

	return (
		<Modal
			animationType="fade"
			onRequestClose={props.onClose}
			transparent
			visible={props.activePicker !== null}
		>
			<Pressable
				onPress={props.onClose}
				style={chatScreenStyles.selectModalBackdrop}
				testID="chat-select-modal-backdrop"
			>
				<Pressable
					onPress={() => {
						// no-op
					}}
					style={chatScreenStyles.selectModalPanel}
				>
					<Text style={chatScreenStyles.selectModalTitle}>{getSelectModalTitle(props.activePicker)}</Text>
					<ScrollView
						contentContainerStyle={chatScreenStyles.selectModalList}
						onContentSizeChange={restoreScrollPosition}
						onScroll={handleScroll}
						ref={scrollViewRef}
						scrollEventThrottle={16}
						showsVerticalScrollIndicator={false}
					>
						{props.options}
					</ScrollView>
				</Pressable>
			</Pressable>
		</Modal>
	);
});
