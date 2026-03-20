const DEAD_KEY_TO_COMBINING_MARK = new Map<string, string>([
	["~", "\u0303"],
	["\u02DC", "\u0303"],
	["`", "\u0300"],
	["\u00B4", "\u0301"],
	["'", "\u0301"],
	["^", "\u0302"],
	["\u00A8", "\u0308"],
]);

export const normalizeDeadKeyCompositionValue = (value: string): string => {
	let normalized = "";

	for (let index = 0; index < value.length; index += 1) {
		const current = value[index];
		const next = value[index + 1];
		const combiningMark = DEAD_KEY_TO_COMBINING_MARK.get(current);
		if (!combiningMark || !next) {
			normalized += current;
			continue;
		}

		const normalizedNext = next.normalize("NFD");
		if (normalizedNext.length >= 2 && normalizedNext[1] === combiningMark) {
			continue;
		}

		normalized += current;
	}

	return normalized;
};
