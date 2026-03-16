import { X, ArrowUpCircle } from "lucide-react";

interface UpdateBannerProps {
	latestVersion: string;
	onDismiss: () => void;
	onDownload: () => void;
}

export const UpdateBanner = ({ latestVersion, onDismiss, onDownload }: UpdateBannerProps): JSX.Element => (
	<div className="flex items-center justify-between gap-3 border-b border-sky-400/20 bg-sky-500/10 px-4 py-2">
		<div className="flex items-center gap-2 text-[13px] text-sky-200">
			<ArrowUpCircle className="h-4 w-4 shrink-0 text-sky-400" />
			<span>
				Version <strong>{latestVersion}</strong> is available.
			</span>
		</div>
		<div className="flex items-center gap-2">
			<button
				className="rounded-md bg-sky-500/20 px-3 py-1 text-[12px] font-medium text-sky-100 transition hover:bg-sky-500/30"
				onClick={onDownload}
				type="button"
			>
				Download
			</button>
			<button
				aria-label="Dismiss update notification"
				className="rounded-md p-1 text-sky-300/60 transition hover:bg-white/5 hover:text-sky-200"
				onClick={onDismiss}
				type="button"
			>
				<X className="h-3.5 w-3.5" />
			</button>
		</div>
	</div>
);
