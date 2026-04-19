import { Loader2, WifiOff } from "lucide-react";
import type { ConnectionState } from "../../features/workspace/model/useWorkspaceStore";

interface ConnectionStatusBannerProps {
	state: ConnectionState;
}

export const ConnectionStatusBanner = ({ state }: ConnectionStatusBannerProps): JSX.Element | null => {
	if (state !== "disconnected" && state !== "reconnecting") {
		return null;
	}

	const isReconnecting = state === "reconnecting";

	return (
		<div
			className="flex items-center justify-between gap-3 border-b border-amber-400/20 bg-amber-500/10 px-4 py-1.5"
			role="status"
			aria-live="polite"
		>
			<div className="flex items-center gap-2 text-[12px] text-amber-100">
				{isReconnecting ? (
					<Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-amber-300" />
				) : (
					<WifiOff className="h-3.5 w-3.5 shrink-0 text-amber-300" />
				)}
				<span>
					{isReconnecting
						? "Reconnecting to the backend…"
						: "Connection lost. Streaming and live updates are paused."}
				</span>
			</div>
		</div>
	);
};
