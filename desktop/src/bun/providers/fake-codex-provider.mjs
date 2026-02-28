
const args = process.argv.slice(2);

const parseArguments = () => {
	const parsed = {
		chatId: "",
		fail: false,
		text: "",
	};

	for (let index = 0; index < args.length; index += 1) {
		const key = args[index];

		switch (key) {
		case "--chat-id": {
			parsed.chatId = args[index + 1] ?? "";
			index += 1;
		
		break;
		}
		case "--fail": {
			parsed.fail = true;
		
		break;
		}
		case "--text": {
			parsed.text = args[index + 1] ?? "";
			index += 1;
		
		break;
		}

		// No default
		}
	}

	return parsed;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

const chunkText = (value, size = 18) => {
	const chunks = [];

	for (let index = 0; index < value.length; index += size) {
		chunks.push(value.slice(index, index + size));
	}

	return chunks;
};

const generateDeterministicResponse = (text) => `Echo: ${text}`;

const main = async () => {
	const parsed = parseArguments();
	const finalText = generateDeterministicResponse(parsed.text);

	emit({ threadId: `thread-${parsed.chatId}`, type: "thread.started" });
	await sleep(10);
	emit({ turnId: `turn-${parsed.chatId}`, type: "turn.started" });
	await sleep(10);
	emit({ item: { text: "Thinking...", type: "reasoning" }, type: "item.started" });
	await sleep(10);
	emit({ item: { text: "Thinking done.", type: "reasoning" }, type: "item.completed" });
	await sleep(10);
	emit({ item: { role: "assistant", type: "assistant_message" }, type: "item.started" });

	const chunks = chunkText(finalText, 20);

	for (const chunk of chunks) {
		await sleep(50);
		emit({
			delta: chunk,
			item: { delta: chunk, type: "assistant_message" },
			type: "item.delta",
		});
	}

	emit({
		item: { role: "assistant", text: finalText, type: "assistant_message" },
		text: finalText,
		type: "item.completed",
	});

	const usage = {
		diff: {
			added: finalText.length,
			removed: Math.max(0, finalText.length - 1),
		},
	};

	emit({
		diffAdded: usage.diff.added,
		diffRemoved: usage.diff.removed,
		type: "turn.completed",
		usage,
	});

	if (parsed.fail) {
		await sleep(10);
		emit({
			error: "forced failure",
			message: "forced failure",
			type: "process.failed",
		});
		process.exit(1);
	}
};

main().catch((error) => {
	process.stdout.write(
		JSON.stringify({
			error: error instanceof Error ? error.message : String(error),
			message: "provider crashed",
			type: "process.failed",
		}),
	);
	process.stdout.write("\n");
	process.exit(1);
});
