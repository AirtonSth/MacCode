import { MaterialIcons } from "@expo/vector-icons";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
	ActivityIndicator,
	FlatList,
	Modal,
	Pressable,
	ScrollView,
	StyleSheet,
	Text,
	View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { RemoteCodeClient } from "../../../shared/api/remotecode-client";
import type { FsEntryDTO, FsListResponseDTO, FsRootEntryDTO } from "../../../shared/api/types";

const palette = {
	accent: "#63C8FF",
	accentPressed: "#4EAAD9",
	background: "#0D0F14",
	border: "rgba(255,255,255,0.11)",
	muted: "#98A0AF",
	text: "#F1F4FA",
};

interface BreadcrumbPart {
	label: string;
	path: string;
}

interface LoadDirectoryOptions {
	silentError?: boolean;
	silentLoading?: boolean;
}

interface DesktopFilePickerModalProps {
	client: Pick<RemoteCodeClient, "listFsEntries" | "listFsRoots">;
	isVisible: boolean;
	onAddPaths: (paths: string[]) => void;
	onClose: () => void;
}

const WINDOWS_DRIVE_PATH_PATTERN = /^[A-Za-z]:\\/u;

const dedupeValues = (values: string[]): string[] => {
	const seen = new Set<string>();
	const ordered: string[] = [];

	for (const value of values) {
		if (!value || seen.has(value)) {
			continue;
		}

		seen.add(value);
		ordered.push(value);
	}

	return ordered;
};

const toErrorMessage = (error: unknown, fallback: string): string => {
	if (!(error instanceof Error)) {
		return fallback;
	}

	switch (error.message) {
		case "invalid_path": {
			return "The selected path is invalid.";
		}
		case "not_directory": {
			return "This path is not a directory.";
		}
		case "not_found": {
			return "This path was not found.";
		}
		default: {
			return error.message.trim().length > 0 ? error.message : fallback;
		}
	}
};

const findPreferredRootPath = (roots: FsRootEntryDTO[]): string | null => {
	const homeRoot = roots.find((root) => root.label.trim().toLowerCase() === "home");
	return homeRoot?.path ?? roots[0]?.path ?? null;
};

const toUnixBreadcrumbs = (path: string): BreadcrumbPart[] => {
	const breadcrumbs: BreadcrumbPart[] = [{ label: "/", path: "/" }];
	const segments = path.split("/").filter((segment) => segment.length > 0);
	let currentPath = "";

	for (const segment of segments) {
		currentPath = `${currentPath}/${segment}`;
		breadcrumbs.push({
			label: segment,
			path: currentPath,
		});
	}

	return breadcrumbs;
};

const toWindowsBreadcrumbs = (path: string): BreadcrumbPart[] => {
	const normalized = path.replaceAll("/", "\\");
	const drive = normalized.slice(0, 2);
	const segments = normalized.slice(2).replace(/^\\+/u, "").split(/\\+/u).filter((segment) => segment.length > 0);
	const breadcrumbs: BreadcrumbPart[] = [{ label: drive, path: `${drive}\\` }];
	let currentPath = `${drive}\\`;

	for (const segment of segments) {
		currentPath = currentPath.endsWith("\\") ? `${currentPath}${segment}` : `${currentPath}\\${segment}`;
		breadcrumbs.push({
			label: segment,
			path: currentPath,
		});
	}

	return breadcrumbs;
};

const buildBreadcrumbs = (path: string | null): BreadcrumbPart[] => {
	if (!path || path.trim().length === 0) {
		return [];
	}

	if (WINDOWS_DRIVE_PATH_PATTERN.test(path)) {
		return toWindowsBreadcrumbs(path);
	}

	if (path.startsWith("/")) {
		return toUnixBreadcrumbs(path);
	}

	return [{ label: path, path }];
};

export const DesktopFilePickerModal = ({
	client,
	isVisible,
	onAddPaths,
	onClose,
}: DesktopFilePickerModalProps): JSX.Element => {
	const [entries, setEntries] = useState<FsEntryDTO[]>([]);
	const [currentPath, setCurrentPath] = useState<string | null>(null);
	const [parentPath, setParentPath] = useState<string | null>(null);
	const [selectedPaths, setSelectedPaths] = useState<Set<string>>(new Set());
	const [isLoadingRoots, setIsLoadingRoots] = useState<boolean>(false);
	const [isLoadingDirectory, setIsLoadingDirectory] = useState<boolean>(false);
	const [errorMessage, setErrorMessage] = useState<string>("");
	const lastVisitedPathRef = useRef<string | null>(null);
	const insets = useSafeAreaInsets();

	const loadDirectory = useCallback(
		async (
			path: string,
			options: LoadDirectoryOptions = {},
		): Promise<FsListResponseDTO | null> => {
			if (!options.silentLoading) {
				setIsLoadingDirectory(true);
			}
			if (!options.silentError) {
				setErrorMessage("");
			}

			try {
				const listed = await client.listFsEntries(path);
				setCurrentPath(listed.path);
				setParentPath(listed.parentPath);
				setEntries(listed.entries);
				lastVisitedPathRef.current = listed.path;
				return listed;
			} catch (error: unknown) {
				if (!options.silentError) {
					setErrorMessage(toErrorMessage(error, "Unable to load directory."));
				}
				return null;
			} finally {
				if (!options.silentLoading) {
					setIsLoadingDirectory(false);
				}
			}
		},
		[client],
	);

	const initializePicker = useCallback(async () => {
		setIsLoadingRoots(true);
		setErrorMessage("");
		setSelectedPaths(new Set());
		setEntries([]);
		setCurrentPath(null);
		setParentPath(null);

		try {
			const nextRoots = await client.listFsRoots();
			if (nextRoots.length === 0) {
				setErrorMessage("No filesystem roots available.");
				return;
			}

			const candidates = dedupeValues([
				lastVisitedPathRef.current ?? "",
				findPreferredRootPath(nextRoots) ?? "",
				nextRoots[0]?.path ?? "",
			]);

			const tryLoadCandidate = async (candidatePaths: string[]): Promise<boolean> => {
				const [firstPath, ...remainingPaths] = candidatePaths;
				if (!firstPath) {
					return false;
				}

				const listed = await loadDirectory(firstPath, {
					silentError: true,
					silentLoading: true,
				});

				if (listed) {
					return true;
				}

				return await tryLoadCandidate(remainingPaths);
			};

			const didLoadDirectory = await tryLoadCandidate(candidates);

			if (!didLoadDirectory) {
				setErrorMessage("Unable to load filesystem entries. Try another root.");
			}
		} catch (error: unknown) {
			setErrorMessage(toErrorMessage(error, "Unable to load filesystem roots."));
		} finally {
			setIsLoadingRoots(false);
		}
	}, [client, loadDirectory]);

	useEffect(() => {
		if (!isVisible) {
			return;
		}

		void initializePicker();
	}, [initializePicker, isVisible]);

	const breadcrumbs = useMemo(() => buildBreadcrumbs(currentPath), [currentPath]);
	const selectedCount = selectedPaths.size;
	const isCurrentFolderSelected = Boolean(currentPath && selectedPaths.has(currentPath));

	const togglePathSelection = useCallback((path: string) => {
		setSelectedPaths((currentSelected) => {
			const nextSelected = new Set(currentSelected);
			if (nextSelected.has(path)) {
				nextSelected.delete(path);
			} else {
				nextSelected.add(path);
			}
			return nextSelected;
		});
	}, []);

	const handleOpenParent = useCallback(() => {
		if (!parentPath) {
			return;
		}

		void loadDirectory(parentPath);
	}, [loadDirectory, parentPath]);

	const handleOpenBreadcrumb = useCallback(
		(path: string) => {
			void loadDirectory(path);
		},
		[loadDirectory],
	);

	const handleToggleCurrentFolder = useCallback(() => {
		if (!currentPath) {
			return;
		}

		togglePathSelection(currentPath);
	}, [currentPath, togglePathSelection]);

	const handleRetry = useCallback(() => {
		if (currentPath) {
			void loadDirectory(currentPath);
			return;
		}

		void initializePicker();
	}, [currentPath, initializePicker, loadDirectory]);

	const handleAdd = useCallback(() => {
		if (selectedCount === 0) {
			return;
		}

		onAddPaths(Array.from(selectedPaths));
	}, [onAddPaths, selectedCount, selectedPaths]);

	const handleUnselectAll = useCallback(() => {
		if (selectedPaths.size === 0) {
			return;
		}

		setSelectedPaths(new Set());
	}, [selectedPaths.size]);

	return (
		<Modal
			animationType="slide"
			onRequestClose={onClose}
			presentationStyle="fullScreen"
			visible={isVisible}
		>
			<View style={styles.root} testID="chat-file-picker-modal">
				<View style={styles.header}>
					<View style={styles.headerTopRow}>
						<Pressable
							onPress={onClose}
							style={({ pressed }) => [
								styles.headerCancelButton,
								pressed ? styles.actionPressed : null,
							]}
							testID="chat-file-picker-cancel-button"
						>
							<Text style={styles.headerCancelLabel}>Cancel</Text>
						</Pressable>
						<Text style={styles.headerTitle}>{selectedCount > 0 ? `${String(selectedCount)} selected` : ""}</Text>
						<Pressable
							disabled={selectedCount === 0}
							onPress={handleUnselectAll}
							style={({ pressed }) => [
								styles.headerUnselectButton,
								selectedCount === 0 ? styles.actionDisabled : null,
								pressed && selectedCount > 0 ? styles.actionPressed : null,
							]}
							testID="chat-file-picker-unselect-all-button"
						>
							<Text style={styles.headerUnselectLabel}>Unselect All</Text>
						</Pressable>
					</View>

				</View>

				<View style={styles.pathBar}>
					<Pressable
						disabled={!parentPath || isLoadingDirectory}
						onPress={handleOpenParent}
						style={({ pressed }) => [
							styles.pathUpButton,
							!parentPath || isLoadingDirectory ? styles.actionDisabled : null,
							pressed && parentPath ? styles.actionPressed : null,
						]}
						testID="chat-file-picker-parent-button"
					>
						<MaterialIcons color={palette.text} name="arrow-upward" size={16} />
					</Pressable>
					<ScrollView
						contentContainerStyle={styles.breadcrumbsContent}
						horizontal
						showsHorizontalScrollIndicator={false}
					>
						{breadcrumbs.map((breadcrumb, index) => (
							<View key={breadcrumb.path} style={styles.breadcrumbItem}>
								<Pressable
									onPress={() => {
										handleOpenBreadcrumb(breadcrumb.path);
									}}
									style={({ pressed }) => [
												styles.breadcrumbButton,
												styles.breadcrumbButtonBackground,
												pressed ? styles.actionPressed : null,
											]}
										>
											<Text numberOfLines={1} style={styles.breadcrumbLabel}>
												{breadcrumb.label}
									</Text>
								</Pressable>
								{index < breadcrumbs.length - 1 ? (
									<Text style={styles.breadcrumbSeparator}>/</Text>
								) : null}
							</View>
						))}
					</ScrollView>
				</View>

				<View style={styles.content}>
					{isLoadingRoots || (isLoadingDirectory && entries.length === 0) ? (
						<View style={styles.centeredState}>
							<ActivityIndicator color={palette.accent} size="small" />
							<Text style={styles.centeredStateText}>Loading desktop files...</Text>
						</View>
					) : null}

					{!isLoadingRoots && errorMessage.length > 0 ? (
						<View style={styles.errorState}>
							<Text selectable style={styles.errorText}>
								{errorMessage}
							</Text>
							<Pressable
								onPress={handleRetry}
								style={({ pressed }) => [
									styles.retryButton,
									pressed ? styles.actionPressed : null,
								]}
								testID="chat-file-picker-retry-button"
							>
								<Text style={styles.retryButtonLabel}>Retry</Text>
							</Pressable>
						</View>
					) : null}

					{!isLoadingRoots && errorMessage.length === 0 ? (
						<FlatList
							contentContainerStyle={entries.length === 0 ? styles.emptyListContent : styles.listContent}
							data={entries}
							keyExtractor={(entry) => entry.path}
							renderItem={({ index, item }) => {
								const isDirectory = item.type === "directory";
								const isSelected = selectedPaths.has(item.path);
								const entryTestID = isDirectory
									? `chat-file-picker-directory-entry-${String(index)}`
									: `chat-file-picker-file-entry-${String(index)}`;
								const trailingIcon = (() => {
									if (isDirectory) {
										return <MaterialIcons color={palette.muted} name="chevron-right" size={18} />;
									}
									if (isSelected) {
										return <MaterialIcons color={palette.accent} name="check-circle" size={18} />;
									}
									return <MaterialIcons color={palette.muted} name="radio-button-unchecked" size={17} />;
								})();

								return (
									<View testID={`chat-file-picker-entry-${String(index)}`}>
										<Pressable
											onPress={() => {
												if (isDirectory) {
													void loadDirectory(item.path);
												} else {
													togglePathSelection(item.path);
												}
											}}
											style={({ pressed }) => [
												styles.entryRow,
												isSelected ? styles.entryRowSelected : null,
												pressed ? styles.entryRowPressed : null,
											]}
											testID={entryTestID}
										>
											<MaterialIcons
												color={isDirectory ? "#7CB7FF" : palette.text}
												name={isDirectory ? "folder" : "description"}
												size={19}
											/>
											<Text numberOfLines={1} style={styles.entryLabel}>
												{item.name}
											</Text>
											{trailingIcon}
										</Pressable>
									</View>
								);
							}}
							showsVerticalScrollIndicator={false}
						/>
					) : null}

					{!isLoadingRoots && errorMessage.length === 0 && entries.length === 0 ? (
						<Text style={styles.emptyState}>This folder is empty.</Text>
					) : null}
				</View>

				<View style={[styles.footer, { paddingBottom: Math.max(16, insets.bottom) }]}>
					<Pressable
						disabled={!currentPath}
						onPress={handleToggleCurrentFolder}
						style={({ pressed }) => [
							styles.footerSecondaryButton,
							isCurrentFolderSelected ? styles.footerSecondaryButtonActive : null,
							!currentPath ? styles.actionDisabled : null,
							pressed && currentPath ? styles.actionPressed : null,
						]}
						testID="chat-file-picker-select-folder-button"
					>
						<Text style={styles.footerSecondaryLabel}>
							{isCurrentFolderSelected ? "Unselect Current Folder" : "Select Current Folder"}
						</Text>
					</Pressable>
					<Pressable
						disabled={selectedCount === 0}
						onPress={handleAdd}
						style={({ pressed }) => [
							styles.footerPrimaryButton,
							selectedCount === 0 ? styles.actionDisabled : null,
							pressed && selectedCount > 0 ? styles.footerPrimaryButtonPressed : null,
						]}
						testID="chat-file-picker-add-button"
					>
						<Text style={styles.footerPrimaryLabel}>{`Add ${String(selectedCount)} item${selectedCount === 1 ? "" : "s"}`}</Text>
					</Pressable>
				</View>
			</View>
		</Modal>
	);
};

const styles = StyleSheet.create({
	root: {
		backgroundColor: palette.background,
		flex: 1,
		paddingHorizontal: 12,
		paddingTop: 56,
	},
	header: {
		paddingBottom: 6,
	},
	headerTopRow: {
		alignItems: "center",
		flexDirection: "row",
		justifyContent: "space-between",
		gap: 10,
	},
	headerTitle: {
		color: palette.text,
		flex: 1,
		fontSize: 19,
		fontWeight: "700",
		textAlign: "center",
	},
	headerCancelButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.04)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		justifyContent: "center",
		paddingHorizontal: 11,
		paddingVertical: 8,
		marginBottom: 8,
	},
	headerCancelLabel: {
		color: palette.text,
		fontSize: 12,
		fontWeight: "600",
	},
	headerUnselectButton: {
		alignItems: "center",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		justifyContent: "center",
		minWidth: 88,
		paddingHorizontal: 11,
		paddingVertical: 8,
		marginBottom: 8,
	},
	headerUnselectLabel: {
		color: palette.muted,
		fontSize: 12,
		fontWeight: "600",
	},
	pathBar: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.10)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		flexDirection: "row",
		gap: 8,
		minHeight: 42,
		paddingHorizontal: 8,
		paddingVertical: 6,
	},
	pathUpButton: {
		alignItems: "center",
		borderColor: palette.border,
		borderRadius: 8,
		borderWidth: 1,
		height: 28,
		justifyContent: "center",
		width: 28,
	},
	breadcrumbsContent: {
		alignItems: "center",
		gap: 2,
	},
	breadcrumbItem: {
		alignItems: "center",
		flexDirection: "row",
	},
	breadcrumbButton: {
		borderRadius: 6,
		paddingHorizontal: 6,
		paddingVertical: 4,
	},
	breadcrumbButtonBackground: {
		backgroundColor: "rgba(255,255,255,0.08)",
	},
	breadcrumbLabel: {
		color: palette.text,
		fontSize: 12,
	},
	breadcrumbSeparator: {
		color: palette.muted,
		fontSize: 11,
		paddingHorizontal: 2,
	},
	content: {
		flex: 1,
		paddingTop: 10,
	},
	centeredState: {
		alignItems: "center",
		flex: 1,
		gap: 10,
		justifyContent: "center",
	},
	centeredStateText: {
		color: palette.muted,
		fontSize: 13,
	},
	errorState: {
		alignItems: "center",
		backgroundColor: "rgba(255,140,162,0.1)",
		borderColor: "rgba(255,140,162,0.36)",
		borderRadius: 12,
		borderWidth: 1,
		gap: 10,
		padding: 14,
	},
	errorText: {
		color: palette.text,
		fontSize: 13,
		textAlign: "center",
	},
	retryButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.08)",
		borderColor: palette.border,
		borderRadius: 9,
		borderWidth: 1,
		paddingHorizontal: 12,
		paddingVertical: 8,
	},
	retryButtonLabel: {
		color: palette.text,
		fontSize: 12,
		fontWeight: "600",
	},
	listContent: {
		gap: 8,
		paddingBottom: 14,
	},
	emptyListContent: {
		flexGrow: 1,
		paddingBottom: 14,
	},
	entryRow: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.03)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		flexDirection: "row",
		gap: 10,
		paddingHorizontal: 10,
		paddingVertical: 10,
	},
	entryRowSelected: {
		backgroundColor: "rgba(99,200,255,0.13)",
		borderColor: "rgba(99,200,255,0.66)",
	},
	entryRowPressed: {
		opacity: 0.84,
	},
	entryLabel: {
		color: palette.text,
		flex: 1,
		fontSize: 13,
	},
	emptyState: {
		color: palette.muted,
		fontSize: 13,
		paddingTop: 12,
		textAlign: "center",
	},
	footer: {
		borderTopColor: palette.border,
		borderTopWidth: 1,
		gap: 8,
		paddingBottom: 16,
		paddingTop: 10,
	},
	footerSecondaryButton: {
		alignItems: "center",
		backgroundColor: "rgba(255,255,255,0.04)",
		borderColor: palette.border,
		borderRadius: 10,
		borderWidth: 1,
		paddingHorizontal: 12,
		paddingVertical: 10,
	},
	footerSecondaryButtonActive: {
		backgroundColor: "rgba(99,200,255,0.14)",
		borderColor: "rgba(99,200,255,0.66)",
	},
	footerSecondaryLabel: {
		color: palette.text,
		fontSize: 13,
		fontWeight: "600",
	},
	footerPrimaryButton: {
		alignItems: "center",
		backgroundColor: palette.accent,
		borderRadius: 10,
		paddingHorizontal: 12,
		paddingVertical: 11,
	},
	footerPrimaryButtonPressed: {
		backgroundColor: palette.accentPressed,
	},
	footerPrimaryLabel: {
		color: "#0A1D2B",
		fontSize: 13,
		fontWeight: "700",
	},
	actionDisabled: {
		opacity: 0.45,
	},
	actionPressed: {
		opacity: 0.8,
	},
});
