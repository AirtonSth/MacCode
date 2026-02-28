import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "../../lib/utils";

const buttonVariants = cva(
	"inline-flex items-center justify-center whitespace-nowrap rounded-xl text-sm font-semibold transition-all duration-200 disabled:pointer-events-none disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
	{
		defaultVariants: {
			size: "default",
			variant: "default",
		},
		variants: {
			size: {
				default: "h-10 px-4 py-2",
				icon: "h-9 w-9 rounded-lg",
				lg: "h-11 rounded-2xl px-6 text-base",
				sm: "h-8 rounded-lg px-3 text-xs",
			},
			variant: {
				default: "bg-primary text-primary-foreground shadow-[0_12px_40px_rgba(56,189,248,0.3)] hover:bg-primary/90",
				destructive: "bg-destructive text-destructive-foreground hover:bg-destructive/90",
				ghost: "bg-transparent text-foreground hover:bg-white/10",
				outline: "border border-white/15 bg-white/5 text-foreground hover:bg-white/10",
				secondary: "bg-secondary text-secondary-foreground hover:bg-secondary/85",
			},
		},
	},
);

export interface ButtonProps
	extends React.ButtonHTMLAttributes<HTMLButtonElement>,
		VariantProps<typeof buttonVariants> {
	asChild?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
	({ className, variant, size, asChild = false, ...props }, ref) => {
		const Comp = asChild ? Slot : "button";
		return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />;
	},
);

Button.displayName = "Button";

export { Button, buttonVariants };
