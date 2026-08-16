let meta = #{
    name: "bots-todo-inspector-drafts",
    description: "Key Studio/Desk inspector memory, skill, and routine drafts by BotID so they do not leak across teammates",
    when_to_use: "When Bots inspector drafts leak across bots (TODO inspector-drafts)",
    phases: [
        #{ title: "Isolate", detail: "stash/restore inspector drafts in adoptSelectedBot like composer drafts" },
        #{ title: "Test", detail: "add isolation, save-clears, delete, and relaunch tests" },
        #{ title: "Prove", detail: "build worktree app and computer-use Memory/Skills/Routines on two bots" },
    ],
};
