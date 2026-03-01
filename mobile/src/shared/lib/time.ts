export const formatRelativeTime = (dateString: string): string => {
	const timestamp = new Date(dateString).getTime();

	if (Number.isNaN(timestamp)) {
		return "now";
	}

	const difference = Math.max(0, Date.now() - timestamp);

	if (difference < 60_000) {
		return "now";
	}

	const minutes = Math.floor(difference / 60_000);

	if (minutes < 60) {
		return `${minutes}m`;
	}

	const hours = Math.floor(minutes / 60);

	if (hours < 24) {
		return `${hours}h`;
	}

	const days = Math.floor(hours / 24);

	return `${days}d`;
};
