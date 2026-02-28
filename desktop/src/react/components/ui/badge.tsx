import { cva, type VariantProps } from "class-variance-authority";
import type { HTMLAttributes } from "react";
import { cn } from "../../lib/utils";

const badgeVariants = cva(
	"inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-semibold tracking-wide",
	{
		defaultVariants: {
			variant: "default",
		},
		variants: {
			variant: {
				default: "border-transparent bg-primary/20 text-primary",
				destructive: "border-transparent bg-destructive/20 text-destructive-foreground",
				outline: "border-white/20 text-foreground",
				secondary: "border-white/15 bg-white/10 text-slate-200",
			},
		},
	},
);

export interface BadgeProps extends HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

export const Badge = ({ className, variant, ...props }: BadgeProps) => (
	<div className={cn(badgeVariants({ variant }), className)} {...props} />
);
