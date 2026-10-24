let meta = #{
    name: "bots-desk-agent-chat",
    description: "Make Bots Desk live chat match Agent App: Thinking, Thought, Work so far, working strip",
    when_to_use: "When Desk chat is missing Agent App thinking, Thought, Work so far, or the live working strip",
    phases: [
        #{ title: "Inventory", detail: "Agent App live turn vs Desk gap list" },
        #{ title: "Implement", detail: "extract shared live-turn chrome and wire Desk" },
        #{ title: "Verify", detail: "skeptic must see Thinking and Work so far in Desk" },
        #{ title: "Repair", detail: "close rejected thinking gaps if the skeptic fails" },
        #{ title: "Proof", detail: "tests, build, computer-use screenshot of live thinking" },
    ],
};

let gap_schema = #{
    "type": "object",
    "required": ["summary", "gaps"],
    "properties": #{
        "summary": #{ "type": "string" },
        "gaps": #{ "type": "array", "items": #{ "type": "string" } },
        "reuse": #{ "type": "array", "items": #{ "type": "string" } },
        "data_path": #{ "type": "string" },
    },
};

let step_schema = #{
    "type": "object",
    "required": ["status", "summary"],
    "properties": #{
        "status": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "commits": #{ "type": "array", "items": #{ "type": "string" } },
        "files": #{ "type": "array", "items": #{ "type": "string" } },
        "proof": #{ "type": "string" },
        "blockers": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let macos = if args == () || args.macos_root == () {
    "/Users/samuelfajreldines/dev/remote-code/macos-app"
} else {
    args.macos_root
};
let do_push = if args == () || args.push == () { false } else { args.push == true };

fn join_list(items) {
    let out = "";
    if items == () { return out; }
    for s in items {
        if type_of(s) == "string" && s != "" {
            if out != "" { out += " | "; }
            out += s;
        }
    }
    out
}

fn field_str(obj, fallback) {
    if obj == () { return fallback; }
    if type_of(obj) == "string" { return obj; }
    fallback
}

fn rules(macos, do_push) {
    let s = "";
    s += "Work only in " + macos + ". ";
    s += "Goal: Bots Desk chat must look and behave like Agent App chat for a live turn. ";
    s += "The user complaint is that thinking does not appear. A composer Thinking pill is not enough. ";
    s += "Agent App live composition is: user bubble -> Thinking…/Thought row -> Work so far (all non-final tools) -> final assistant markdown. ";
    s += "Read Sources/Surfaces/AgentAppSurface.swift around reasoningRow (Thinking… / Thought) and completedWorkLabel (Work so far / Worked). ";
    s += "Read Sources/Surfaces/AgentChatUXPresentation.swift (AgentWorkingStripPresentation, AgentWorkingCatCopy, Work so far expand policy). ";
    s += "Read Sources/CoreModel/AssistantEvents.swift AssistantTimelineState.apply. ";
    s += "Agent App loads live items via coordinator.latestStreamEvents(threadId:) then timeline.apply. Desk already has linkedAgentThreadID and starts a supervised run. ";
    s += "Do not embed the full Agent App window (no thread rail, plan, Auto, execution/worktree). ";
    s += "Do not touch Token Saver, Distill, RCW1, or Codex-owned files. Extracting View builders from AgentAppSurface is allowed only if Agent App tests still pass and Token Saver hide-set logic stays in Agent App. ";
    s += "Do not use git add -A. Stage only files you changed. ";
    s += "Another Codex agent may use computer-use on /tmp/remotecode-rcw1-e2e-* and windows 32765/32873. Never click, move, resize, or kill those. Target only this worktree dist/RemoteCode.app. ";
    s += "Honesty Desktop stays: Same macOS account; not isolated. Not a dedicated Desktop. ";
    s += "User workflow state must survive close/reopen: replay persisted stream events for the linked thread when Desk opens. ";
    if do_push {
        s += "After commit, rebase onto origin/main if behind without dropping Codex commits, then git push origin HEAD. ";
    } else {
        s += "Do not push. ";
    }
    s += "Do not ask the user questions.";
    s
}

let common = rules(macos, do_push);

phase("Inventory");
let app_prompt = "";
app_prompt += common;
app_prompt += " Read-only. Inventory Agent App live-turn UI. Use grep and read_file. ";
app_prompt += " List every view/state the user sees while a turn is live: Thinking…, Thought expand, Work so far, Worked, tool rows, working cat copy, workingPhase, stop. ";
app_prompt += " Name the exact functions, accessibility identifiers, and how latestStreamEvents become AssistantTimelineState. ";
app_prompt += " gaps = Agent App pieces Desk must reuse. reuse = existing public types (AgentChatTranscriptChrome, AgentWorkingStripPresentation, AgentChatUXPresentation). data_path = how Desk can subscribe without a second provider run. ";
app_prompt += " Do not edit.";

let desk_prompt = "";
desk_prompt += common;
desk_prompt += " Read-only. Inventory Bots Desk chat as shipped. Use grep and read_file on BotsWindow.swift, BotsDeskFollowThrough.swift, AgentChatTranscriptChrome.swift, BotsWindowTests.swift. ";
desk_prompt += " Report what Desk paints today (persisted bubbles + Supervised run work-log + composer Thinking pill). ";
desk_prompt += " gaps = missing Agent App live pieces. reuse = what already matches (composer attach/send, user bubble, markdown reply). data_path = linkedAgentThreadID / restoreDeskWorkLog / sendAgentMessage. ";
desk_prompt += " Do not edit.";

let inventory = parallel([
    #{
        prompt: app_prompt,
        label: "inventory-agent-app",
        capability_mode: "read-only",
        output_schema: gap_schema,
    },
    #{
        prompt: desk_prompt,
        label: "inventory-desk",
        capability_mode: "read-only",
        output_schema: gap_schema,
    },
]);

let app_inv = if inventory.len() > 0 { inventory[0] } else { () };
let desk_inv = if inventory.len() > 1 { inventory[1] } else { () };
let app_out = if app_inv != () && app_inv.success { app_inv.output } else { () };
let desk_out = if desk_inv != () && desk_inv.success { desk_inv.output } else { () };
let app_summary = if app_out != () { field_str(app_out.summary, "") } else { "" };
let desk_summary = if desk_out != () { field_str(desk_out.summary, "") } else { "" };
let app_gaps = if app_out != () { join_list(app_out.gaps) } else { "" };
let desk_gaps = if desk_out != () { join_list(desk_out.gaps) } else { "" };
let desk_path = if desk_out != () { field_str(desk_out.data_path, "") } else { "" };
let app_path = if app_out != () { field_str(app_out.data_path, "") } else { "" };
let data_path = if desk_path != "" { desk_path } else { app_path };
log("inventory agent-app: " + app_summary);
log("inventory desk: " + desk_summary);

phase("Implement");
let impl_prompt = "";
impl_prompt += common;
impl_prompt += " Implement Desk live-turn chrome so thinking appears the way Agent App does. ";
impl_prompt += " Inventory Agent App: " + app_summary + " gaps: " + app_gaps + ". ";
impl_prompt += " Inventory Desk: " + desk_summary + " gaps: " + desk_gaps + ". ";
impl_prompt += " Data path hint: " + data_path + ". ";
impl_prompt += " Required product behavior: ";
impl_prompt += "1) While the linked run streams reasoning, Desk shows an expandable row labeled Thinking… with the live body. When reasoning finishes it collapses to Thought (chevron, same a11y family as agent.reasoning.*). ";
impl_prompt += "2) Tools/commands/file changes live inside a Work so far disclosure (Work so far · N steps in this turn when live and count>1). After the turn finishes it becomes Worked / Worked for Xs. Live Work so far defaults open; it collapses when a final answer arrives. ";
impl_prompt += "3) Final assistant markdown stays outside Work so far, left-aligned, using AgentChatAssistantReply. ";
impl_prompt += "4) Composer working strip must use AgentWorkingStripPresentation with real hasStreamingTools from live items, plus AgentWorkingCatCopy rotating status like Agent App (agent.workingStatus / agent.workingPhase). A work-log Working pill alone is not enough. ";
impl_prompt += "5) Hide the generic Supervised run work-log panel from the chat column when live-turn chrome is painting Thinking/Work so far. Keep work-log mapping if Attention still needs it. ";
impl_prompt += "6) On openDesk / reopen, replay coordinator.latestStreamEvents(threadId:) (or the same public router API) into a published AssistantTimelineState so Thought/Worked survive close/reopen. Do not start a second provider run. ";
impl_prompt += " Implementation approach: extract reasoning + Work so far View builders into a public shared type (prefer AgentChatTranscriptChrome or a new AgentChatLiveTurnChrome.swift). Call it from Desk. Agent App may call the extracted views if that is the smallest safe reuse; do not rewrite Agent App Token Saver / hide-set / iOS parity. ";
impl_prompt += " Tests must encode WHY, not only WHAT, in Tests/AppShellTests/BotsWindowTests.swift and Tests/SurfacesTests (chrome or new live-turn tests). Cover: streaming Thinking… vs finished Thought; Work so far owns tools; final outside; working strip sees tools; reopen replays events. ";
impl_prompt += " After tests pass, commit with a focused message. Build with bash script/build_and_run.sh --verify. ";
impl_prompt += " Return status=shipped only if tests you added pass. ";

let implemented = agent(impl_prompt, #{
    label: "implement-desk-live-turn",
    capability_mode: "all",
    output_schema: step_schema,
});
if implemented == () || !implemented.success {
    complete(#{
        status: "BLOCKED",
        step: "Implement",
        detail: "implementer failed",
        agent_app_inventory: app_out,
        desk_inventory: desk_out,
    });
}
log("implement: " + field_str(implemented.output.summary, ""));

phase("Verify");
let verify_prompt = "";
verify_prompt += common;
verify_prompt += " Adversarial read-only review. The claim is: Bots Desk now shows Agent App thinking (Thinking… / Thought) and Work so far, not just a work-log pill. ";
verify_prompt += " Read the actual diff and shipped files. Set status=confirmed only if you independently see: ";
verify_prompt += "(a) Desk timeline paints reasoning from AssistantTimelineState / live items, ";
verify_prompt += "(b) Thinking… while streaming and Thought when finished, ";
verify_prompt += "(c) Work so far owns non-final tools, ";
verify_prompt += "(d) tests that would fail if thinking disappeared. ";
verify_prompt += " If the implementer only restyled the Supervised run pill or the composer Thinking label, status=rejected. ";
verify_prompt += " summary must cite file paths and identifiers. proof = evidence quotes. ";
verify_prompt += " Implementer claimed: " + field_str(implemented.output.summary, "");

let verified = agent(verify_prompt, #{
    label: "verify-thinking-visible",
    capability_mode: "read-only",
    output_schema: step_schema,
});
let verify_out = if verified != () && verified.success { verified.output } else { () };
let verify_status = if verify_out != () { field_str(verify_out.status, "unverified") } else { "unverified" };
log("verify: " + verify_status + " " + field_str(if verify_out != () { verify_out.summary } else { () }, ""));

let latest = implemented;
if verify_status != "confirmed" {
    phase("Repair");
    let repair_prompt = "";
    repair_prompt += common;
    repair_prompt += " Skeptic rejected or failed. Fix Desk so thinking is really visible. ";
    repair_prompt += " Skeptic: " + field_str(if verify_out != () { verify_out.summary } else { () }, "no skeptic output") + ". ";
    repair_prompt += " Do not argue. Read the files. Close every rejected gap. Re-run the tests you touch. Commit. ";
    repair_prompt += " status=shipped only after tests pass.";
    let repaired = agent(repair_prompt, #{
        label: "repair-desk-live-turn",
        capability_mode: "all",
        output_schema: step_schema,
    });
    if repaired == () || !repaired.success {
        complete(#{
            status: "BLOCKED",
            step: "Repair",
            detail: "repair agent failed",
            implement: implemented.output,
            verify: verify_out,
        });
    }
    latest = repaired;
    log("repair: " + field_str(repaired.output.summary, ""));
}

phase("Proof");
let proof_prompt = "";
proof_prompt += common;
proof_prompt += " Do not add features unless a test or live UI still lacks Thinking…/Thought/Work so far. ";
proof_prompt += " Run the focused Swift tests you added plus BotsWindowTests / AgentChatTranscriptChromeTests / AgentChatUXPresentationTests as relevant. ";
proof_prompt += " bash script/build_and_run.sh --verify. If verify says no onscreen window because an old instance is running, open dist/RemoteCode.app. ";
proof_prompt += " Computer-use: target_app io.remotecode.desktop, focus_strategy none. Open Bots via the Agentic/Bots toggle or bots.home.chat. Open a bot Desk. Send a short message from bots.desk.composer. ";
proof_prompt += " Capture a screenshot of THIS worktree window only. Proof requires visible Thinking… or Thought and/or Work so far in the Desk transcript, not only a composer pill. ";
proof_prompt += " Never touch Codex CUA windows or /tmp/remotecode-rcw1-e2e-*. ";
proof_prompt += " Write a short evidence report. status=proven only if you saw thinking in the live Desk. ";

let proof = agent(proof_prompt, #{
    label: "proof-live-thinking",
    capability_mode: "all",
    output_schema: step_schema,
});
let proof_out = if proof != () && proof.success { proof.output } else { () };
let proof_text = if proof_out != () { field_str(proof_out.proof, field_str(proof_out.summary, "no proof")) } else { "Proof agent did not return usable evidence." };
let report = write_scratch_file("bots-desk-agent-chat-proof.md", proof_text);

let final_status = "PARTIAL";
if proof_out != () && field_str(proof_out.status, "") == "proven" {
    final_status = "DONE";
}

complete(#{
    status: final_status,
    report: report,
    agent_app_inventory: app_out,
    desk_inventory: desk_out,
    implement: latest.output,
    verify: verify_out,
    proof: proof_out,
});
