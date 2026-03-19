import { memo } from "react";
import {
	Modal,
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
					<ScrollView contentContainerStyle={chatScreenStyles.selectModalList} showsVerticalScrollIndicator={false}>
						{props.options}
					</ScrollView>
				</Pressable>
			</Pressable>
		</Modal>
	);
});
