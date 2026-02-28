import { integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const projects = sqliteTable("projects", {
	createdAt: text("createdAt").notNull(),
	id: text("id").primaryKey(),
	isFavorite: integer("isFavorite").notNull().default(0),
	name: text("name").notNull(),
	path: text("path").notNull().unique(),
	updatedAt: text("updatedAt").notNull(),
});

export const chats = sqliteTable("chats", {
	diffAdded: integer("diffAdded").notNull().default(0),
	diffRemoved: integer("diffRemoved").notNull().default(0),
	id: text("id").primaryKey(),

	projectId: text("projectId")
		.notNull()
		.references(() => projects.id, { onDelete: "cascade" }),

	provider: text("provider").notNull(),
	status: text("status").notNull(),
	title: text("title").notNull(),
	updatedAt: text("updatedAt").notNull(),
});

export const messages = sqliteTable("messages", {
	chatId: text("chatId")
		.notNull()
		.references(() => chats.id, { onDelete: "cascade" }),

	content: text("content").notNull(),
	createdAt: text("createdAt").notNull(),
	id: text("id").primaryKey(),
	role: text("role").notNull(),
});

export type ChatRow = typeof chats.$inferSelect;
export type MessageRow = typeof messages.$inferSelect;
export type ProjectRow = typeof projects.$inferSelect;
