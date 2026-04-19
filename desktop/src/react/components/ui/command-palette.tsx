import { Command as CmdkCommand } from "cmdk";
import type { ComponentType, ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { cn } from "../../lib/utils";

type AnyProps = { children?: ReactNode } & Record<string, unknown>;
const Command = CmdkCommand as unknown as ComponentType<AnyProps> & {
	Input: ComponentType<AnyProps>;
	List: ComponentType<AnyProps>;
	Empty: ComponentType<AnyProps>;
	Group: ComponentType<AnyProps>;
	Item: ComponentType<AnyProps>;
};

export interface CommandPaletteItem {
	id: string;
	label: string;
	hint?: string;
	shortcut?: string;
	keywords?: string[];
	group?: string;
	disabled?: boolean;
	onSelect: () => void | Promise<void>;
}

export interface CommandPaletteProps {
	open: boolean;
	onOpenChange: (open: boolean) => void;
	items: CommandPaletteItem[];
	placeholder?: string;
	emptyMessage?: string;
}

export function CommandPalette({
	open,
	onOpenChange,
	items,
	placeholder = "Type a command or search…",
	emptyMessage = "No matching command.",
}: CommandPaletteProps) {
	const [search, setSearch] = useState("");

	useEffect(() => {
		if (!open) {
			setSearch("");
		}
	}, [open]);

	const groupedItems = useMemo(() => {
		const map = new Map<string, CommandPaletteItem[]>();
		for (const item of items) {
			const key = item.group ?? "Commands";
			const bucket = map.get(key);
			if (bucket) {
				bucket.push(item);
			} else {
				map.set(key, [item]);
			}
		}
		return Array.from(map.entries());
	}, [items]);

	useEffect(() => {
		if (!open) return;
		const handler = (event: KeyboardEvent) => {
			if (event.key === "Escape") {
				onOpenChange(false);
			}
		};
		document.addEventListener("keydown", handler);
		return () => document.removeEventListener("keydown", handler);
	}, [open, onOpenChange]);

	if (!open) {
		return null;
	}

	return (
		<div
			className="fixed inset-0 z-[9999] flex items-start justify-center bg-black/60 px-4 pt-[14vh] backdrop-blur-sm"
			onClick={() => onOpenChange(false)}
			role="presentation"
		>
			<div
				className="w-full max-w-xl overflow-hidden rounded-2xl border border-white/10 bg-[#0d0f14]/95 shadow-[0_30px_90px_rgba(0,0,0,0.55)]"
				onClick={(event) => event.stopPropagation()}
				role="dialog"
				aria-modal="true"
				aria-label="Command palette"
			>
				<Command label="Command palette" className="flex flex-col">
					<Command.Input
						autoFocus
						placeholder={placeholder}
						value={search}
						onValueChange={setSearch}
						className="h-12 w-full border-b border-white/10 bg-transparent px-4 text-sm text-foreground placeholder:text-muted-foreground/70 focus:outline-none"
					/>
					<Command.List className="max-h-[360px] overflow-y-auto py-2">
						<Command.Empty className="px-4 py-6 text-center text-xs text-muted-foreground">
							{emptyMessage}
						</Command.Empty>
						{groupedItems.map(([group, groupItems]) => (
							<Command.Group
								key={group}
								heading={group}
								className="px-2 text-[10px] font-semibold uppercase tracking-widest text-muted-foreground/70 [&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:pt-2 [&_[cmdk-group-heading]]:pb-1"
							>
								{groupItems.map((item) => (
									<Command.Item
										key={item.id}
										value={[item.label, item.hint, ...(item.keywords ?? [])].filter(Boolean).join(" ")}
										disabled={item.disabled}
										onSelect={() => {
											onOpenChange(false);
											void item.onSelect();
										}}
										className={cn(
											"flex cursor-pointer items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm text-foreground",
											"aria-selected:bg-white/10 data-[disabled=true]:opacity-50 data-[disabled=true]:cursor-not-allowed",
										)}
									>
										<span className="flex min-w-0 flex-col">
											<span className="truncate">{item.label}</span>
											{item.hint ? (
												<span className="truncate text-xs text-muted-foreground">{item.hint}</span>
											) : null}
										</span>
										{item.shortcut ? (
											<kbd className="shrink-0 rounded border border-white/10 bg-white/5 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground">
												{item.shortcut}
											</kbd>
										) : null}
									</Command.Item>
								))}
							</Command.Group>
						))}
					</Command.List>
				</Command>
			</div>
		</div>
	);
}
