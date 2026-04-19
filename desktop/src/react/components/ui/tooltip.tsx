import * as React from "react";
import * as TooltipPrimitive from "@radix-ui/react-tooltip";
import { cn } from "../../lib/utils";

const TooltipProvider = TooltipPrimitive.Provider;

const Tooltip = TooltipPrimitive.Root;

const TooltipTrigger = TooltipPrimitive.Trigger;

const TooltipContent = React.forwardRef<
	React.ElementRef<typeof TooltipPrimitive.Content>,
	React.ComponentPropsWithoutRef<typeof TooltipPrimitive.Content>
>(({ className, sideOffset = 8, ...props }, ref) => (
	<TooltipPrimitive.Portal>
		<TooltipPrimitive.Content
			className={cn(
				"z-50 overflow-hidden rounded-lg border border-white/15 bg-slate-900/95 px-3 py-1.5 text-xs text-slate-100 shadow-[0_16px_36px_rgba(0,0,0,0.45)] backdrop-blur-md animate-in fade-in-0 zoom-in-95",
				className,
			)}
			ref={ref}
			sideOffset={sideOffset}
			{...props}
		/>
	</TooltipPrimitive.Portal>
));

TooltipContent.displayName = TooltipPrimitive.Content.displayName;

export { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger };
