let meta = #{
    name: "plan-connection-dual-track",
    description: "Implement plan-connection dual-track (S-001..S-009) with checkpoint commits and proofs",
    phases: [
        #{ title: "Bootstrap", detail: "branch + report + gap freeze" },
        #{ title: "S-001", detail: "taxonomy + silent_catchup.v1 + honesty UX" },
        #{ title: "S-002-S-007", detail: "metrics funnel + token dual-write" },
        #{ title: "S-003-S-004", detail: "singleflight transport + iOS exclusive catch-up" },
        #{ title: "S-005-S-006", detail: "Mac Phase A wakes + selective catch-up" },
        #{ title: "S-008-S-009", detail: "risk matrix + flags + runbooks" },
        #{ title: "Proof", detail: "build/test macOS+iOS + device proof" },
    ],
    when_to_use: "Execute or resume plan-connection dual-track implementation with live report.html",
};

let step_schema = #{
    "type": "object",
    "required": ["status", "summary", "commits", "proof", "report_updated"],
    "properties": #{
        "status": #{ "type": "string" },
        "summary": #{ "type": "string" },
        "commits": #{ "type": "array", "items": #{ "type": "string" } },
        "proof": #{ "type": "string" },
        "report_updated": #{ "type": "boolean" },
        "blockers": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

let plan_dir = if args == () || args.plan_dir == () {
    "/Users/samuelfajreldines/dev/remote-code/plan-connection"
} else {
    args.plan_dir
};
let report = plan_dir + "/report.html";
let macos = if args == () || args.macos_root == () {
    "/Users/samuelfajreldines/dev/remote-code/macos-app"
} else {
    args.macos_root
};
let ios = if args == () || args.ios_root == () {
    "/Users/samuelfajreldines/dev/remote-code/ios-app"
} else {
    args.ios_root
};

phase("Bootstrap");
log("plan-connection dual-track: report=" + report);

phase("S-001");
let s001_prompt = "";
s001_prompt += "Implement plan-connection S-001 fully if not already done. ";
s001_prompt += "Repos: " + plan_dir + "/report.html and plan-report.json. ";
s001_prompt += "Repos: macos=" + macos + " branch feat/plan-connection-dual-track; ios=" + ios + " same branch. ";
s001_prompt += "Deliver: MaterialWakeTaxonomy, silent_catchup.v1 contract both sides, ConnectionHonestyState UI, BACKGROUND-LIMITS taxonomy, unit tests, commits per repo, append timeline to report.html. ";
s001_prompt += "Do not ask questions. Preserve unrelated dirty work. ";
s001_prompt += "Return status/summary/commits/proof/report_updated.";
let s001 = agent(s001_prompt, #{
    label: "S-001",
    capability_mode: "all",
    output_schema: step_schema,
});
if s001 == () || !s001.success {
    complete(#{ status: "BLOCKED", step: "S-001", detail: "agent failed" });
}

phase("S-002-S-007");
let s002_prompt = "";
s002_prompt += "Implement plan-connection S-002 instrumentation funnel and S-007 token dual-write/revoke. ";
s002_prompt += "Read " + report + " first. Repos: " + macos + ", " + ios + ". ";
s002_prompt += "Commit checkpoints, run tests, update report.html. No questions.";
let s002 = agent(s002_prompt, #{
    label: "S-002-S-007",
    capability_mode: "all",
    output_schema: step_schema,
});

phase("S-003-S-004");
let s003_prompt = "";
s003_prompt += "Implement S-003 singleflight recovery and S-004 exclusive nested catch-up. ";
s003_prompt += "Read " + report + ". Commit+test+update report. No questions.";
let s003 = agent(s003_prompt, #{
    label: "S-003-S-004",
    capability_mode: "all",
    output_schema: step_schema,
});

phase("S-005-S-006");
let s005_prompt = "";
s005_prompt += "Implement S-005 Phase A Mac silent wakes (expand deliverSilentCatchUp, flags default off) and S-006 selective catch-up consumer. ";
s005_prompt += "Read " + report + ". Commit+test+update report. No questions.";
let s005 = agent(s005_prompt, #{
    label: "S-005-S-006",
    capability_mode: "all",
    output_schema: step_schema,
});

phase("S-008-S-009");
let s008_prompt = "";
s008_prompt += "Implement S-008 risk matrix/canary docs/tests and S-009 flags+runbooks+BACKGROUND-LIMITS honesty. ";
s008_prompt += "Read " + report + ". Commit+test+update report. No questions.";
let s008 = agent(s008_prompt, #{
    label: "S-008-S-009",
    capability_mode: "all",
    output_schema: step_schema,
});

phase("Proof");
let proof_prompt = "";
proof_prompt += "Prove plan-connection dual-track: run unit tests macOS+iOS, build apps, open macOS app and iOS simulator, exercise connection honesty UI and silent catch-up paths with computer-use where possible. ";
proof_prompt += "Append evidence to " + report + ". Goal complete only with concrete proof. No questions.";
let proof = agent(proof_prompt, #{
    label: "proof",
    capability_mode: "all",
    output_schema: step_schema,
});

complete(#{
    status: "DONE",
    report: report,
    s001: s001.output,
    s002: if s002 != () && s002.success { s002.output } else { () },
    s003: if s003 != () && s003.success { s003.output } else { () },
    s005: if s005 != () && s005.success { s005.output } else { () },
    s008: if s008 != () && s008.success { s008.output } else { () },
    proof: if proof != () && proof.success { proof.output } else { () },
});
