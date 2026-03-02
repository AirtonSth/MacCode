import type { ChatDTO } from "../../../shared/api/types";

export interface ThreadSection {
	items: ChatDTO[];
	title: "Today" | "Yesterday" | "Last 7 Days" | "Older";
}

const startOfDay = (input: Date): Date => {
	return new Date(input.getFullYear(), input.getMonth(), input.getDate());
};

const MS_PER_DAY = 24 * 60 * 60 * 1000;

const toSectionTitle = (updatedAt: string, now: Date): ThreadSection["title"] => {
	const updatedDate = new Date(updatedAt);
	const todayStart = startOfDay(now).getTime();
	const updatedStart = startOfDay(updatedDate).getTime();

	if (updatedStart >= todayStart) {
		return "Today";
	}

	if (updatedStart >= todayStart - MS_PER_DAY) {
		return "Yesterday";
	}

	if (updatedStart >= todayStart - (7 * MS_PER_DAY)) {
		return "Last 7 Days";
	}

	return "Older";
};

const sectionOrder: ThreadSection["title"][] = ["Today", "Yesterday", "Last 7 Days", "Older"];

export const buildThreadSections = (
	chats: ChatDTO[],
	options?: {
		now?: Date;
		query?: string;
	},
): ThreadSection[] => {
	const normalizedQuery = options?.query?.trim().toLowerCase() ?? "";
	const now = options?.now ?? new Date();

	const filtered = normalizedQuery.length === 0
		? chats
		: chats.filter((chat) => chat.title.toLowerCase().includes(normalizedQuery));

	const sorted = Array.from(filtered).sort(
		(left, right) => new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime(),
	);

	const grouped = new Map<ThreadSection["title"], ChatDTO[]>();
	for (const chat of sorted) {
		const title = toSectionTitle(chat.updatedAt, now);
		const current = grouped.get(title) ?? [];
		current.push(chat);
		grouped.set(title, current);
	}

	return sectionOrder
		.map((title) => ({
			items: grouped.get(title) ?? [],
			title,
		}))
		.filter((section) => section.items.length > 0);
};
