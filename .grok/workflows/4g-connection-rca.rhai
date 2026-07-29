let meta = #{
    name: "4g-connection-rca",
    description: "Investigate and list all iOS 4G/off-LAN connection failure causes with adversarial verification",
    when_to_use: "When 4G+Tailscale or non-LAN connect is broken or slow",
    phases: [
        #{ title: "Inventory", detail: "parallel read-only scans of connect path seams" },
        #{ title: "Synthesize", detail: "ranked root causes + fix plan" },
        #{ title: "Verify", detail: "adversarial check each claimed cause against code" },
    ],
};

let causes_schema = #{
    "type": "object",
    "required": ["causes"],
    "properties": #{
        "causes": #{
            "type": "array",
            "maxItems": 12,
            "items": #{
                "type": "object",
                "required": ["id", "severity", "file", "issue", "why_4g"],
                "properties": #{
                    "id": #{ "type": "string" },
                    "severity": #{ "type": "string" },
                    "file": #{ "type": "string" },
                    "issue": #{ "type": "string" },
                    "why_4g": #{ "type": "string" },
                },
            },
        },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["real", "reason", "evidence"],
    "properties": #{
        "real": #{ "type": "boolean" },
        "reason": #{ "type": "string" },
        "evidence": #{ "type": "string" },
    },
};

let ios = if args == () { "/Users/samuelfajreldines/dev/remote-code/ios-app" } else if args.ios_root == () {
    "/Users/samuelfajreldines/dev/remote-code/ios-app"
} else {
    args.ios_root
};

phase("Inventory");
let seams = [
    "HostSession.connect Happy Eyeballs race and discovery timeouts",
    "EventStreamClient liveness welcome snapshot heartbeat budgets by path vs quality policy",
    "HostHTTPClient operationTimeout discovery vs cellular path policy",
    "autoReconnectIfPossible recovering toast and scene phase races",
    "Bonjour disabled on cellular and saved Tailscale MagicDNS host promotion",
    "HostContinuity preferredOrder overlay vs RFC1918 on expensive path",
];
let jobs = [];
for s in seams {
    let p = "You are a read-only RCA investigator for RemoteCode iOS 4G/off-LAN connect.\n";
    p += "Root: " + ios + "\n";
    p += "Seam: " + s + "\n";
    p += "Use grep and read_file only. Do not edit.\n";
    p += "Find concrete failure modes that make connect fail or feel slow on 4G+Tailscale ";
    p += "(not same Wi-Fi as Mac). Report at most 4 causes as schema objects with severity high|medium|low.\n";
    p += "Every issue must cite file path + why it hits 4G specifically.\n";
    jobs.push(#{
        prompt: p,
        label: "inv:" + s.sub_string(0, 28),
        capability_mode: "read-only",
        output_schema: causes_schema,
    });
}
let inv = parallel(jobs);

let causes = [];
for r in inv {
    if r != () && r.success && r.output.causes != () {
        for c in r.output.causes {
            causes.push(c);
        }
    }
}
if causes.len() == 0 {
    complete(#{ summary: "No causes found by inventory (investigate failed or empty).", causes: [] });
}

// Cap verify fan-out
let max_v = 10;
if causes.len() > max_v {
    log("truncating causes " + causes.len().to_string() + " -> " + max_v.to_string());
    let trimmed = [];
    let i = 0;
    for c in causes {
        if i < max_v { trimmed.push(c); }
        i += 1;
    }
    causes = trimmed;
}

phase("Verify");
let vjobs = [];
for c in causes {
    let vp = "Adversarially verify this claimed 4G connect RCA by reading shipped code under "
        + ios + ".\n";
    vp += "Claim id=" + c.id + " file=" + c.file + " issue=" + c.issue + " why_4g=" + c.why_4g + "\n";
    vp += "Set real=true only with concrete evidence you independently inspected. Else real=false.\n";
    vp += "evidence must quote symbols or line-level facts.";
    vjobs.push(#{
        prompt: vp,
        label: "verify:" + c.id,
        capability_mode: "read-only",
        output_schema: verdict_schema,
    });
}
let verdicts = parallel(vjobs);

let confirmed = [];
let i = 0;
for v in verdicts {
    if v != () && v.success && v.output.real == true
        && v.output.evidence != () && v.output.evidence != "" {
        let row = causes[i];
        confirmed.push(#{
            id: row.id,
            severity: row.severity,
            file: row.file,
            issue: row.issue,
            why_4g: row.why_4g,
            evidence: v.output.evidence,
        });
    }
    i += 1;
}

phase("Synthesize");
let report = "# 4G connection RCA\n\n";
report += "Confirmed causes: " + confirmed.len().to_string() + " / scanned " + causes.len().to_string() + "\n\n";
for c in confirmed {
    report += "## " + c.id + " (" + c.severity + ")\n";
    report += "- file: `" + c.file + "`\n";
    report += "- issue: " + c.issue + "\n";
    report += "- why 4g: " + c.why_4g + "\n";
    report += "- evidence: " + c.evidence + "\n\n";
}
let path = write_scratch_file("4g-connection-rca.md", report);
log("wrote " + path);
complete(#{
    summary: confirmed.len().to_string() + " confirmed 4G connect causes",
    path: path,
    confirmed: confirmed,
});
