let meta = #{
    name: "implement-plan-bots",
    description: "Implement plan-bots P1a Fleet/Studio/Desk UI to the plan concepts, with advisor, commit, push, build, and computer-use at each checkpoint",
    when_to_use: "When RemoteCode Bots must match plan-bots Fleet, Studio, and Desk and each slice must be proven live",
    phases: [
        #{ title: "Survey", detail: "read plan concepts vs shipped Bots UI" },
        #{ title: "Fleet Home", detail: "selected-bot overview beside the roster" },
        #{ title: "Studio", detail: "Brain identity, honesty Desktop, summary" },
        #{ title: "Desk", detail: "timeline, receipt, honesty desktop pane" },
        #{ title: "Inspector", detail: "Memory and Routines as a side inspector" },
        #{ title: "Proof", detail: "build, computer-use, compare Grok Bot" },
    ],
};

let step_schema = #{
    "type": "object",
    "required": ["status", "summary", "commits", "proof"],
    "properties": #{
        "status": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "commits": #{ "type": "array", "items": #{ "type": "string" } },
        "proof": #{ "type": "string" },
        "skipped": #{ "type": "boolean" },
        "blockers": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let plan_dir = if args == () || args.plan_dir == () {
    "/Users/samuelfajreldines/dev/remote-code/plan-bots"
} else {
    args.plan_dir
};
let macos = if args == () || args.macos_root == () {
    "/Users/samuelfajreldines/dev/remote-code/macos-app"
} else {
    args.macos_root
};
let do_push = if args == () || args.push == () { false } else { args.push == true };

fn rules(macos, plan_dir, do_push) {
    let s = "";
    s += "You are implementing RemoteCode Bots in " + macos + ". ";
    s += "The product plan and concept images live in " + plan_dir + " (index.html plus assets/bots-home.png, bot-studio.png, bot-desk.png). ";
    s += "Read those files and the current Sources/AppShell/BotsWindow.swift plus BotsDeskFollowThrough.swift before editing. ";
    s += "Match the plan visual contract: persistent BOT ROSTER, selected-bot overview, Studio Brain, Desk timeline, honesty Desktop. ";
    s += "P1a must not claim a dedicated VM. The honesty label is: Same macOS account; not isolated. Not a dedicated Desktop. ";
    s += "Routines must stay honest: no app-closed execution. ";
    s += "Do not touch Token Saver, Distill, RCW1, AgentAppSurface, or Codex-owned files. ";
    s += "Do not use git add -A. Stage only Bots-owned paths you changed. ";
    s += "Another Codex agent may be editing the same repo and using computer-use on /tmp/remotecode-rcw1-e2e-* and windows 32765/32873. Never click, move, resize, or kill those. Target only this worktree dist/RemoteCode.app. ";
    s += "At every checkpoint: run python3 ~/.grok/skills/sam-codex-advisor/scripts/resolve_advisor.py --model gpt-5.6-sol --effort max, then invoke that argv with the question on stdin. ";
    s += "After advisor, commit with a focused message. ";
    if do_push {
        s += "Then rebase onto origin/production if behind (do not drop Codex commits such as RCW1 fail-open) and git push origin HEAD. ";
    } else {
        s += "Do not push. ";
    }
    s += "Build with bash script/build_and_run.sh --verify. It only kills this worktree binary. ";
    s += "Verify with computer-use MCP: list_windows, screenshot target_window_id of THIS pid only, click_element with focus_strategy none. Compare Grok Bot window com.anysphere.sand via screencapture -l without raising it onto the Codex display. ";
    s += "If the slice is already shipped (matching accessibility ids and live UI), skip edits, still prove it, set skipped=true. ";
    s += "Do not ask the user questions. Return status/summary/commits/proof.";
    s
}

let common = rules(macos, plan_dir, do_push);

phase("Survey");
let survey_prompt = "";
survey_prompt += common;
survey_prompt += " Survey only. Do not edit. Read the plan, the three concept images, BotsWindow.swift, BotTypes.swift, and git log --oneline -8. ";
survey_prompt += " Report what P1a UI already exists versus the concepts. status=surveyed. commits=[].";
let survey = agent(survey_prompt, #{
    label: "survey",
    capability_mode: "read-only",
    output_schema: step_schema,
});
if survey == () || !survey.success {
    complete(#{ status: "BLOCKED", step: "Survey", detail: "survey agent failed" });
}
log("survey: " + survey.output.summary);

phase("Fleet Home");
let fleet_prompt = "";
fleet_prompt += common;
fleet_prompt += " Implement Fleet Home to match assets/bots-home.png as far as P1a honesty allows. ";
fleet_prompt += " Roster stays. Selecting a bot shows an overview: name, job/title, provider chip, last activity, Memory/Skills/Routines/Approvals cards, and a Desktop card that uses the logical-space honesty label. ";
fleet_prompt += " Open Chat opens Desk. Studio opens Bot Studio. Do not render a fake macOS VM. ";
fleet_prompt += " Tests in Tests/AppShellTests/BotsWindowTests.swift must encode why. ";
fleet_prompt += " Checkpoint: tests, advisor gpt-5.6-sol max, commit, push if allowed, build_and_run.sh --verify, computer-use screenshot of Fleet Home.";
let fleet = agent(fleet_prompt, #{
    label: "fleet-home",
    capability_mode: "all",
    output_schema: step_schema,
});
if fleet == () || !fleet.success {
    complete(#{ status: "BLOCKED", step: "Fleet Home", detail: "implementer failed", survey: survey.output });
}

phase("Studio");
let studio_prompt = "";
studio_prompt += common;
studio_prompt += " Implement Bot Studio to match assets/bot-studio.png as far as P1a allows. ";
studio_prompt += " Keep the roster. Studio has Profile plus Memory/Skills/Routines/Desktop tabs or sections. Role and Identity (name, role/title, description). Provider routing Claude/Codex/Grok. Soul/instructions. Desktop options with Not shipped on VM/remote and the honesty caption. Configuration summary on the right. ";
studio_prompt += " Saving publishes a BotRevision. Tests + advisor + commit + push + build + computer-use Studio.";
let studio = agent(studio_prompt, #{
    label: "studio",
    capability_mode: "all",
    output_schema: step_schema,
});
if studio == () || !studio.success {
    complete(#{ status: "BLOCKED", step: "Studio", detail: "implementer failed", fleet: fleet.output });
}

phase("Desk");
let desk_prompt = "";
desk_prompt += common;
desk_prompt += " Implement Bot Desk to match assets/bot-desk.png as far as P1a allows. ";
desk_prompt += " Roster + timeline with timestamps, user/assistant labels, work-log rows when a linked run exists, and a right pane that is either honesty Desktop (logical space, not a fake VM) or empty with the honesty label. ";
desk_prompt += " Show Bot name, handle, job, provider/model, supervised permission. Unread only when this Desk is not open. Follow-through stays conversation-scoped. ";
desk_prompt += " Tests + advisor + commit + push + build + computer-use Desk send and reopen.";
let desk = agent(desk_prompt, #{
    label: "desk",
    capability_mode: "all",
    output_schema: step_schema,
});
if desk == () || !desk.success {
    complete(#{ status: "BLOCKED", step: "Desk", detail: "implementer failed", studio: studio.output });
}

phase("Inspector");
let inspector_prompt = "";
inspector_prompt += common;
inspector_prompt += " Put Memory and Routines in a Grok-like side inspector instead of replacing the chat. ";
inspector_prompt += " Memory: compact add field, list, correct, forget. Routines: Name, Instruction, When, Active, Test run, honesty caption. ";
inspector_prompt += " Test run remains real work; schedules do not run while the app is closed. ";
inspector_prompt += " Tests + advisor + commit + push + build + computer-use Memory add and Routines panel.";
let inspector = agent(inspector_prompt, #{
    label: "inspector",
    capability_mode: "all",
    output_schema: step_schema,
});
if inspector == () || !inspector.success {
    complete(#{ status: "BLOCKED", step: "Inspector", detail: "implementer failed", desk: desk.output });
}

phase("Proof");
let proof_prompt = "";
proof_prompt += common;
proof_prompt += " Do not add features. Prove the live app against the three concept images and Grok Bot. ";
proof_prompt += " bash script/build_and_run.sh --verify. Computer-use only window of this worktree. ";
proof_prompt += " Walk Fleet Home, Studio, Desk send, Memory, Routines. Capture Grok Bot with screencapture -l without raising it onto the Codex display. ";
proof_prompt += " Write scratch/plan-bots-proof.md with what matches, what is still bar, and P1b+ leftovers. ";
proof_prompt += " status=proven only if you actually opened the app.";
let proof = agent(proof_prompt, #{
    label: "proof",
    capability_mode: "all",
    output_schema: step_schema,
});

let proof_out = if proof != () && proof.success { proof.output } else { () };
let report = "";
if proof_out != () && proof_out.proof != () {
    report = write_scratch_file("plan-bots-proof.md", proof_out.proof);
} else {
    report = write_scratch_file("plan-bots-proof.md", "Proof agent did not return usable evidence.");
}

complete(#{
    status: if proof_out != () && proof_out.status == "proven" { "DONE" } else { "PARTIAL" },
    report: report,
    survey: survey.output,
    fleet: fleet.output,
    studio: studio.output,
    desk: desk.output,
    inspector: inspector.output,
    proof: proof_out,
});
