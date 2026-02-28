import type { Config } from "tailwindcss";
import animate from "tailwindcss-animate";

const config = {
	content: ["./src/react/**/*.{ts,tsx,html}"],
	darkMode: ["class"],
	theme: {
		container: {
			center: true,
			padding: "1rem",
			screens: {
				"2xl": "1400px",
			},
		},
		extend: {
			colors: {
				background: "hsl(var(--background))",
				foreground: "hsl(var(--foreground))",
				card: "hsl(var(--card))",
				"card-foreground": "hsl(var(--card-foreground))",
				popover: "hsl(var(--popover))",
				"popover-foreground": "hsl(var(--popover-foreground))",
				primary: "hsl(var(--primary))",
				"primary-foreground": "hsl(var(--primary-foreground))",
				secondary: "hsl(var(--secondary))",
				"secondary-foreground": "hsl(var(--secondary-foreground))",
				muted: "hsl(var(--muted))",
				"muted-foreground": "hsl(var(--muted-foreground))",
				accent: "hsl(var(--accent))",
				"accent-foreground": "hsl(var(--accent-foreground))",
				destructive: "hsl(var(--destructive))",
				"destructive-foreground": "hsl(var(--destructive-foreground))",
				border: "hsl(var(--border))",
				input: "hsl(var(--input))",
				ring: "hsl(var(--ring))",
				sidebar: "hsl(var(--sidebar))",
				"sidebar-foreground": "hsl(var(--sidebar-foreground))",
				"sidebar-border": "hsl(var(--sidebar-border))",
			},
			borderRadius: {
				lg: "var(--radius)",
				md: "calc(var(--radius) - 2px)",
				sm: "calc(var(--radius) - 6px)",
			},
			keyframes: {
				"pulse-soft": {
					"0%, 100%": { opacity: "0.2" },
					"50%": { opacity: "0.9" },
				},
			},
			animation: {
				"pulse-soft": "pulse-soft 1.4s ease-in-out infinite",
			},
		},
	},
	plugins: [animate],
} satisfies Config;

export default config;
