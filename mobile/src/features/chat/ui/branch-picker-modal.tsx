import { MaterialIcons } from "@expo/vector-icons";
import { useEffect, useMemo, useState } from "react";
import {
	Modal,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	TextInput,
	View,
} from "react-native";

const palette = {
	text: "#F1F4FA",
};

interface BranchPickerModalProps {
	isVisible: boolean;
	branches: string[];
	currentBranch: string | null;
	changedFiles?: number;
	added?: number;
	removed?: number;
	isDisabled?: boolean;
	isLoading?: boolean;
	isGitRepository: boolean;
	onClose: () => void;
	onCheckoutBranch: (branch: string) => Promise<void> | void;
	onCreateBranch: (name: string) => Promise<void> | void;
}

export const BranchPickerModal = ({
	isVisible,
	branches,
	currentBranch,
	changedFiles = 0,
	added = 0,
	removed = 0,
	isDisabled = false,
	isLoading = false,
	isGitRepository,
	onClose,
	onCheckoutBranch,
	onCreateBranch,
}: BranchPickerModalProps): JSX.Element => {
	const [searchTerm, setSearchTerm] = useState("");
	const [isCreateMode, setIsCreateMode] = useState(false);
	const [newBranchName, setNewBranchName] = useState("");
	const [isSubmitting, setIsSubmitting] = useState(false);
	const [errorMessage, setErrorMessage] = useState<string | null>(null);

	const normalizedFilter = searchTerm.trim().toLowerCase();
	const 	isActionDisabled = isDisabled || isLoading || isSubmitting || !isGitRepository;

	const filteredBranches = useMemo(
		() =>
			branches.filter((branch) => {
				if (normalizedFilter.length === 0) {
					return true;
				}

				return branch.toLowerCase().includes(normalizedFilter);
			}),
		[branches, normalizedFilter],
	);

	useEffect(() => {
		if (isVisible) {
			return;
		}

		setSearchTerm("");
		setIsCreateMode(false);
		setNewBranchName("");
		setErrorMessage(null);
	}, [isVisible]);

	const handleCheckout = async (branch: string) => {
		if (!branch || isActionDisabled) {
			return;
		}

		setErrorMessage(null);
		setIsSubmitting(true);
		try {
			await Promise.resolve(onCheckoutBranch(branch));
			onClose();
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to checkout branch.");
		} finally {
			setIsSubmitting(false);
		}
	};

	const handleCreate = async () => {
		if (isActionDisabled) {
			return;
		}

		const normalizedBranchName = newBranchName.trim();
		if (normalizedBranchName.length === 0) {
			return;
		}

		setErrorMessage(null);
		setIsSubmitting(true);
		try {
			await Promise.resolve(onCreateBranch(normalizedBranchName));
			onClose();
		} catch (error) {
			setErrorMessage(error instanceof Error ? error.message : "Unable to create branch.");
		} finally {
			setIsSubmitting(false);
		}
	};

	return (
		<Modal animationType="fade" onRequestClose={onClose} transparent visible={isVisible}>
			<Pressable
				onPress={onClose}
				style={styles.backdrop}
				testID="chat-branch-modal-backdrop"
			>
				<Pressable onPress={() => {
					// no-op
				}} style={styles.panel}>
					<View style={styles.searchContainer}>
						<MaterialIcons color="#9CA1AB" name="search" size={16} />
						<TextInput
							autoCapitalize="none"
							autoFocus
							editable={!isActionDisabled}
							onChangeText={setSearchTerm}
							placeholder="Search branches"
							placeholderTextColor="#989DA7"
							style={styles.searchInput}
							testID="chat-branch-search-input"
							value={searchTerm}
						/>
					</View>

					<Text style={styles.sectionLabel}>Branches</Text>

					<ScrollView contentContainerStyle={styles.list} showsVerticalScrollIndicator={false} style={styles.listScroll}>
						{filteredBranches.length === 0 ? (
							<Text style={styles.emptyLabel}>
								{isLoading ? "Loading local branches..." : "No local branches match your search"}
							</Text>
						) : (
							filteredBranches.map((branch) => {
								const isCurrent = branch === currentBranch;
								return (
									<Pressable
										disabled={isActionDisabled}
										key={branch}
										onPress={() => {
											void handleCheckout(branch);
										}}
										style={({ pressed }) => [
											styles.branchItem,
											isCurrent ? styles.branchItemActive : null,
											pressed ? styles.branchItemPressed : null,
										]}
										testID={`chat-branch-option-${branch}`}
									>
										<View style={styles.branchRow}>
											<View style={styles.branchInfo}>
												<View style={styles.branchNameRow}>
													<MaterialIcons color="#D6D9E0" name="account-tree" size={15} />
													<Text numberOfLines={1} style={styles.branchName}>
														{branch}
													</Text>
												</View>
												{isCurrent ? (
													<Text numberOfLines={1} style={styles.branchMeta}>
														Changes: {changedFiles} · <Text style={styles.branchAdded}>+{added}</Text> /{" "}
														<Text style={styles.branchRemoved}>-{removed}</Text>
													</Text>
												) : null}
											</View>

											{isCurrent ? <MaterialIcons color="#F5F7FB" name="check" size={16} /> : null}
										</View>
									</Pressable>
								);
							})
						)}
					</ScrollView>

					<View style={styles.footer}>
						{isCreateMode ? (
							<View style={styles.createContainer}>
								<TextInput
									autoCapitalize="none"
									autoFocus
									editable={!isActionDisabled}
									onChangeText={setNewBranchName}
									onSubmitEditing={() => {
										void handleCreate();
									}}
									placeholder="new-branch-name"
									placeholderTextColor="#9197A2"
									style={styles.createInput}
									testID="chat-branch-create-input"
									value={newBranchName}
								/>
								<View style={styles.createActions}>
									<Pressable
										disabled={isActionDisabled}
										onPress={() => {
											setIsCreateMode(false);
											setNewBranchName("");
										}}
										style={({ pressed }) => [
											styles.createCancelButton,
											pressed ? styles.createCancelButtonPressed : null,
										]}
										testID="chat-branch-create-cancel-button"
									>
										<Text style={styles.createCancelLabel}>Cancel</Text>
									</Pressable>
									<Pressable
										disabled={isActionDisabled || newBranchName.trim().length === 0}
										onPress={() => {
											void handleCreate();
										}}
										style={({ pressed }) => [
											styles.createSubmitButton,
											pressed ? styles.createSubmitButtonPressed : null,
											isActionDisabled || newBranchName.trim().length === 0 ? styles.disabledButton : null,
										]}
										testID="chat-branch-create-submit-button"
									>
										<Text style={styles.createSubmitLabel}>Create and checkout</Text>
									</Pressable>
								</View>
							</View>
						) : (
							<Pressable
								disabled={isActionDisabled}
								onPress={() => {
									setIsCreateMode(true);
									setNewBranchName(searchTerm.trim());
								}}
								style={({ pressed }) => [
									styles.createToggleButton,
									pressed ? styles.createToggleButtonPressed : null,
								]}
								testID="chat-branch-create-toggle-button"
							>
								<MaterialIcons color={palette.text} name="add" size={16} />
								<Text numberOfLines={1} style={styles.createToggleLabel}>
									Create and checkout new branch...
								</Text>
							</Pressable>
						)}
					</View>

					{errorMessage ? <Text style={styles.errorMessage}>{errorMessage}</Text> : null}

					{isGitRepository ? null : <Text style={styles.notRepoMessage}>This project is not a git repository.</Text>}
				</Pressable>
			</Pressable>
		</Modal>
	);
};

const styles = StyleSheet.create({
	backdrop: {
		backgroundColor: "rgba(2,5,10,0.62)",
		flex: 1,
		justifyContent: "flex-end",
	},
	panel: {
		backgroundColor: "rgba(20,22,27,0.98)",
		borderTopLeftRadius: 18,
		borderTopRightRadius: 18,
		maxHeight: 460,
		paddingBottom: 20,
		paddingHorizontal: 14,
		paddingTop: 10,
	},
	searchContainer: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.05)",
		borderRadius: 12,
		flexDirection: "row",
		gap: 8,
		paddingHorizontal: 10,
		paddingVertical: 8,
	},
	searchInput: {
		color: "#D7DBE2",
		flex: 1,
		fontSize: 14,
		fontWeight: "500",
		minHeight: 22,
	},
	sectionLabel: {
		color: "#9CA1AA",
		fontSize: 11,
		fontWeight: "700",
		letterSpacing: 1.2,
		paddingBottom: 4,
		paddingTop: 14,
		textTransform: "uppercase",
	},
	listScroll: {
		maxHeight: 240,
	},
	list: {
		gap: 6,
		paddingBottom: 6,
		paddingRight: 2,
	},
	branchItem: {
		backgroundColor: "rgba(255,255,255,0.02)",
		borderColor: "rgba(255,255,255,0.14)",
		borderRadius: 10,
		borderWidth: 1,
		paddingHorizontal: 10,
		paddingVertical: 9,
	},
	branchItemActive: {
		backgroundColor: "rgba(255,255,255,0.03)",
	},
	branchItemPressed: {
		opacity: 0.82,
	},
	branchRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "space-between",
	},
	branchInfo: {
		flex: 1,
		gap: 4,
		minWidth: 0,
	},
	branchNameRow: {
		alignItems: "center",
		flexDirection: "row",
		gap: 7,
		minWidth: 0,
	},
	branchName: {
		color: "#EDF0F4",
		flex: 1,
		fontSize: 14,
		fontWeight: "700",
	},
	branchMeta: {
		color: "#8F949D",
		fontSize: 11,
		paddingLeft: 22,
	},
	branchAdded: {
		color: "#34D399",
		fontWeight: "700",
	},
	branchRemoved: {
		color: "#FB7185",
		fontWeight: "700",
	},
	emptyLabel: {
		color: "#8F959F",
		fontSize: 12,
		paddingHorizontal: 2,
		paddingVertical: 8,
	},
	footer: {
		borderTopColor: "rgba(255,255,255,0.10)",
		borderTopWidth: 1,
		marginTop: 4,
		paddingTop: 8,
	},
	createContainer: {
		gap: 8,
	},
	createInput: {
		backgroundColor: "rgba(255,255,255,0.06)",
		borderColor: "rgba(255,255,255,0.15)",
		borderRadius: 9,
		borderWidth: 1,
		color: "#E4E8EF",
		fontSize: 12,
		paddingHorizontal: 10,
		paddingVertical: 8,
	},
	createActions: {
		alignItems: "center",
		flexDirection: "row",
		gap: 8,
		justifyContent: "flex-end",
	},
	createCancelButton: {
		borderRadius: 8,
		paddingHorizontal: 8,
		paddingVertical: 6,
	},
	createCancelButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.06)",
	},
	createCancelLabel: {
		color: "#A8ADB6",
		fontSize: 11,
	},
	createSubmitButton: {
		backgroundColor: "rgba(255,255,255,0.12)",
		borderRadius: 8,
		paddingHorizontal: 10,
		paddingVertical: 6,
	},
	createSubmitButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.18)",
	},
	createSubmitLabel: {
		color: "#EDF1F6",
		fontSize: 11,
		fontWeight: "600",
	},
	createToggleButton: {
		alignItems: "center",
		borderRadius: 8,
		flexDirection: "row",
		gap: 6,
		paddingHorizontal: 8,
		paddingVertical: 8,
	},
	createToggleButtonPressed: {
		backgroundColor: "rgba(255,255,255,0.04)",
	},
	createToggleLabel: {
		color: palette.text,
		flex: 1,
		fontSize: 14,
		fontWeight: "500",
	},
	disabledButton: {
		opacity: 0.5,
	},
	errorMessage: {
		color: "#FDA4AF",
		fontSize: 11,
		paddingHorizontal: 2,
		paddingTop: 8,
	},
	notRepoMessage: {
		color: "#FDA4AF",
		fontSize: 11,
		paddingHorizontal: 2,
		paddingTop: 8,
	},
});
