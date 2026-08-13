import Foundation

/// Deterministic compiler for one bounded, common orchestration shape:
/// discover one prioritized work item, implement it under explicit constraints,
/// then update the tracker. Every non-empty source line must bind to one typed
/// slot or the compiler returns nil and the caller keeps the lossless `u:` wire.
enum SR2NaturalTaskCompiler {
    private struct Selection {
        let ordinal: String
        let entity: String
        let status: String
        let assignee: String
    }

    private struct PriorityPreference {
        let value: String
        let matchLocus: String
    }

    private struct Implementation {
        let branch: String
        let issue: String
        let skills: [String]
        let advisor: String
        let advisorConfiguration: String
        let commitObject: String
        let followedSkill: String
    }

    private struct Deliverable {
        let artifact: String
        let destination: String
        let presentation: String
    }

    private struct RepositoryMapping {
        let label: String
        let role: String?
        let url: String
    }

    static func candidate(for source: String) -> String? {
        linearOrchestrationCandidate(for: source)
            ?? trackerDeliveryCandidate(for: source)
    }

    private static func linearOrchestrationCandidate(for source: String) -> String? {
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 9,
              let openTarget = openTarget(in: lines[0]),
              let selection = selection(in: lines[1]),
              isHTTPSURL(lines[2]),
              let priority = priority(in: lines[3], entity: selection.entity),
              let implementation = implementation(in: lines[4]),
              let updateTarget = updateTarget(in: lines[5]),
              let deliverable = deliverable(in: lines[6]),
              let tool = tool(in: lines[7]),
              [
                openTarget, selection.entity, selection.status, selection.assignee,
                priority.value, implementation.branch, implementation.advisorConfiguration,
                implementation.commitObject, updateTarget, deliverable.artifact,
                deliverable.destination, deliverable.presentation, tool,
              ].allSatisfy(isSafeTextAtom) else {
            return nil
        }

        let mappings = lines.dropFirst(8).compactMap(repositoryMapping(in:))
        guard mappings.count == lines.count - 8,
              !mappings.isEmpty,
              mappings.allSatisfy({ mapping in
                  isSafeTextAtom(mapping.label)
                      && (mapping.role.map(isSafeTextAtom) ?? true)
              }),
              Set(mappings.map { $0.label.lowercased() }).count == mappings.count else {
            return nil
        }

        let repositories = mappings.map { mapping in
            let role = mapping.role.map { "(\($0))" } ?? ""
            return "\(mapping.label)\(role)=\(mapping.url)"
        }.joined(separator: "&")
        let skills = implementation.skills.joined(separator: ",")
        let attributes = [
            "wt@updated \(implementation.branch)",
            skills,
            "\(implementation.advisor)(\(implementation.advisorConfiguration))",
            "!review:task",
            "!commit:\(implementation.commitObject)",
            "must:\(implementation.followedSkill):all",
            "must:create:\(deliverable.artifact)+upload:\(deliverable.destination)(\(deliverable.presentation))",
            "tool:\(tool)",
            "repos:\(repositories)",
        ].filter { !$0.isEmpty }.joined(separator: ",")
        let plan = "open:\(openTarget)>pick:\(selection.ordinal) \(selection.entity)(status=\(selection.status),asgn=\(selection.assignee),at=\(lines[2]),prio?=\(priority.value)@\(priority.matchLocus))>impl:\(implementation.issue)(\(attributes))>update:\(updateTarget)"
        return "\(SR2WirePolicy.optimizerMarkerLine)\nt:\(plan)"
    }

    private static func openTarget(in line: String) -> String? {
        captures(#"(?i)^(?:go to|open|visit)\s+(?:my\s+)?(.+?)\.?$"#, in: line)?.first
    }

    private static func selection(in line: String) -> Selection? {
        guard let values = captures(
            #"(?i)^(?:get|find|select)\s+the\s+(first|next|last)\s+(.+?)\s+where\s+status\s+is\s+(.+?)\s+and\s+it(?:'|’)?s\s+assigned\s+to(?:\s+me)?\s+(.+?)\.?$"#,
            in: line
        ), values.count == 4 else { return nil }
        let ordinal = values[0].lowercased() == "first" ? "1st" : values[0].lowercased()
        return Selection(ordinal: ordinal, entity: values[1], status: values[2], assignee: values[3])
    }

    private static func priority(in line: String, entity: String) -> PriorityPreference? {
        guard let values = captures(#"(?i)^(.+?)\s+with\s+(.+?)\s+(?:are|is)\s+priority\.?$"#, in: line),
              values.count == 2,
              singular(values[0]) == singular(entity) else { return nil }
        guard isSafeTextAtom(values[1]) else { return nil }
        return PriorityPreference(value: values[1], matchLocus: "title-or-text")
    }

    private static func implementation(in line: String) -> Implementation? {
        guard let nested = captures(#"(?i)^now\s+do\s+the\s+prompt:\s*[“\"](.+)[”\"]$"#, in: line)?.first,
              let values = captures(
                #"(?i)^using\s+git\s+worktree\s+from\s+updated\s+(\S+)\s+implement:\s+(\S+)\s+(.+?)\s+\(no\s+review\s+(?:da|of\s+the)\s+task\s+use\s+(/[A-Za-z][A-Za-z0-9_-]*)\s+\(([^()]+)\)\)\s+OBS:\s+do\s+not\s+commit\s+the\s+([^.]+)\.\s+Critical:\s+you\s+should\s+follow\s+all\s+([A-Za-z0-9_/-]+)\s+steps$"#,
                in: nested
              ), values.count == 7 else { return nil }
        let skills = values[2].split(whereSeparator: \.isWhitespace).map(String.init)
        guard !skills.isEmpty,
              skills.allSatisfy({ $0.range(of: #"^/[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil }),
              isSafeTextAtom(values[0]),
              isSafeIssueReference(values[1]),
              isSafeTextAtom(values[4]),
              isSafeTextAtom(values[5]) else {
            return nil
        }
        let advisor = values[3]
        let allSkills = skills + [advisor]
        let requestedFollow = values[6].hasPrefix("/") ? values[6] : "/" + values[6]
        guard allSkills.contains(requestedFollow) else { return nil }
        return Implementation(
            branch: values[0],
            issue: values[1],
            skills: skills,
            advisor: advisor,
            advisorConfiguration: values[4],
            commitObject: values[5],
            followedSkill: requestedFollow
        )
    }

    private static func updateTarget(in line: String) -> String? {
        captures(#"(?i)^after\s+update\s+(.+?)\.?$"#, in: line)?.first
    }

    private static func deliverable(in line: String) -> Deliverable? {
        guard let values = captures(
            #"(?i)^it(?:'|’)?s\s+mandatory\s+to\s+create\s+(?:the\s+)?(.+?)\s+and\s+upload\s+them\s+into\s+(.+?)\s+as\s+(.+?)\.?$"#,
            in: line
        ), values.count == 3 else { return nil }
        return Deliverable(artifact: values[0], destination: values[1], presentation: values[2])
    }

    private static func tool(in line: String) -> String? {
        captures(#"(?i)^use\s+(.+?)\s+to\s+help\s+you\.?$"#, in: line)?.first
    }

    private static func repositoryMapping(in line: String) -> RepositoryMapping? {
        guard let values = captures(#"^(.+?)(?:\s+\(([^()]+)\))?:\s+(https://\S+)$"#, in: line),
              values.count == 3,
              isHTTPSURL(values[2]) else { return nil }
        return RepositoryMapping(
            label: values[0],
            role: values[1].isEmpty ? nil : values[1],
            url: values[2]
        )
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ), match.range == NSRange(text.startIndex..<text.endIndex, in: text) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func singular(_ value: String) -> String {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasSuffix("s") ? String(lower.dropLast()) : lower
    }

    private static func isHTTPSURL(_ value: String) -> Bool {
        guard isSafeURLAtom(value),
              !value.contains(where: \.isWhitespace),
              value.hasPrefix("https://"),
              let url = URL(string: value),
              url.scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return false }
        return true
    }

    private static func isSafeIssueReference(_ value: String) -> Bool {
        value.range(of: #"^<[A-Za-z][A-Za-z0-9_-]*>$"#, options: .regularExpression) != nil
            || isHTTPSURL(value)
    }

    /// `t:` uses these characters as structural delimiters. The bounded
    /// compiler has no escaping layer, so accepting one in source data would
    /// let a label or status manufacture a second action/binding.
    private static func isSafeTextAtom(_ value: String) -> Bool {
        !value.isEmpty
            && !containsUnboundSemanticSyntax(value)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !":>(),&=+!@;|?\\".unicodeScalars.contains($0)
            }
    }

    /// Scalar slots cannot carry their own logic. If a captured value contains
    /// a connective, condition, modality, quantifier, or ordering word, the
    /// surrounding bounded grammar has not typed that meaning and must fail
    /// open to the lossless `u:` envelope.
    private static func containsUnboundSemanticSyntax(_ value: String) -> Bool {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let semanticWords: Set<Substring> = [
            "all", "and", "any", "after", "before", "both", "can", "case",
            "could", "critical", "either", "else", "every", "except", "if",
            "mandatory", "may", "might", "must", "never", "not", "once", "only",
            "or", "otherwise", "provided", "required", "should", "then", "unless",
            "until", "when", "while", "will", "with", "without", "would",
            "as", "long", "soon", "because", "since", "where", "whose",
            "ambos", "antes", "apenas", "ate", "caso", "com", "depois", "deve",
            "deveria", "e", "entao", "exceto", "nao", "nunca", "obrigatoria",
            "obrigatorio", "ou", "pode", "qualquer", "se", "sem", "senao",
            "somente", "todas", "todos",
        ]
        return !words.isDisjoint(with: semanticWords)
    }

    private static func isSafeURLAtom(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !">(),&=;|\\".unicodeScalars.contains($0)
            }
    }

    // MARK: - Tracker delivery (Trello / STAR Portuguese goal)

    private struct TrackerDelivery {
        let tracker: String
        let sourceList: String
        let mergeBranch: String
        let destList: String
        let skill: String
        let email: String
        let password: String
        let prTool: String
        let forbiddenPRTool: String
    }

    /// Bounded compiler for the live Portuguese tracker-delivery goal:
    /// pick the first card in a list, implement via a named skill, merge,
    /// verify, comment the PR URL, then move the card. Every remaining
    /// source line must bind or the caller keeps the lossless `u:` wire.
    private static func trackerDeliveryCandidate(for source: String) -> String? {
        var lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = lines.first, isGoalSlashCommand(first) {
            lines.removeFirst()
        }
        lines = collapseLabeledCredentialLines(lines)
        guard !lines.isEmpty else { return nil }

        var pipeline: (tracker: String, sourceList: String, mergeBranch: String, destList: String)?
        var sawBrowser = false
        var skill: String?
        var mustSkill: String?
        var commentTracker: String?
        var commentPRTool: String?
        var sawPostdeploy = false
        var email: String?
        var password: String?
        var sawDone = false
        var prTool: String?
        var forbiddenPRTool: String?

        for line in lines {
            if pipeline == nil, let parsed = deliveryPipeline(in: line) {
                pipeline = parsed
                continue
            }
            if !sawBrowser, isDeliveryBrowser(line) {
                sawBrowser = true
                continue
            }
            if skill == nil, let parsed = deliverySkill(in: line) {
                skill = parsed
                continue
            }
            if mustSkill == nil, let parsed = deliveryMustSkill(in: line) {
                mustSkill = parsed
                continue
            }
            if commentTracker == nil, let parsed = deliveryComment(in: line) {
                commentTracker = parsed.tracker
                commentPRTool = parsed.prTool
                continue
            }
            if !sawPostdeploy, isDeliveryPostdeploy(line) {
                sawPostdeploy = true
                continue
            }
            if email == nil, let parsed = deliveryEmail(in: line) {
                email = parsed
                continue
            }
            if password == nil, let parsed = deliveryPassword(in: line) {
                password = parsed
                continue
            }
            if !sawDone, isDeliveryDone(line) {
                sawDone = true
                continue
            }
            if prTool == nil, let parsed = deliveryPRTools(in: line) {
                prTool = parsed.allowed
                forbiddenPRTool = parsed.forbidden
                continue
            }
            return nil
        }

        guard let pipeline,
              sawBrowser,
              let skill,
              let mustSkill,
              let commentTracker,
              let commentPRTool,
              sawPostdeploy,
              let email,
              let password,
              sawDone,
              let prTool,
              let forbiddenPRTool,
              mustSkill.lowercased() == skill.lowercased(),
              commentTracker.lowercased() == pipeline.tracker.lowercased(),
              commentPRTool.lowercased() == prTool.lowercased(),
              isSafeTextAtom(pipeline.tracker),
              isSafeTextAtom(pipeline.sourceList),
              isSafeTextAtom(pipeline.mergeBranch),
              isSafeTextAtom(pipeline.destList),
              isSafeSkillAtom(skill),
              isSafeEmailAtom(email),
              isSafePasswordAtom(password),
              isSafeTextAtom(prTool),
              isSafeTextAtom(forbiddenPRTool) else {
            return nil
        }

        let delivery = TrackerDelivery(
            tracker: pipeline.tracker.lowercased(),
            sourceList: pipeline.sourceList,
            mergeBranch: pipeline.mergeBranch,
            destList: pipeline.destList,
            skill: skill,
            email: email,
            password: password,
            prTool: prTool.lowercased(),
            forbiddenPRTool: forbiddenPRTool.lowercased()
        )
        return encodeTrackerDelivery(delivery)
    }

    private static func encodeTrackerDelivery(_ delivery: TrackerDelivery) -> String {
        let skillName = delivery.skill.hasPrefix("/")
            ? String(delivery.skill.dropFirst())
            : delivery.skill
        let commentField = delivery.tracker == "trello"
            ? "trello-comment:\(delivery.prTool).PR.url"
            : "comment:\(delivery.tracker)=\(delivery.prTool).PR.url"
        return """
        \(SR2WirePolicy.optimizerMarkerLine)
        goal:\(delivery.tracker).\(delivery.sourceList)[0]>implement>verify>merge:\(delivery.mergeBranch)>verify-merge>\(delivery.tracker):\(delivery.destList)
        use:\(delivery.tracker)-skill,\(delivery.skill)
        must:\(delivery.skill).all,\(delivery.skill).playwright,postdeploy-test
        browser:chrome|computer-use?
        auth:\(delivery.email)|\(delivery.password)
        pr:\(delivery.prTool),!\(delivery.forbiddenPRTool)
        \(commentField)
        done:\(skillName).all+playwright+deploy+postdeploy-test+merge-verified+\(delivery.tracker)-\(delivery.destList.lowercased())
        """
    }

    private static func isGoalSlashCommand(_ line: String) -> Bool {
        fold(line).range(of: #"^/goal\.?$"#, options: .regularExpression) != nil
    }

    private static func collapseLabeledCredentialLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBareCredentialLabel(line), index + 1 < lines.count {
                result.append("\(line) \(lines[index + 1])")
                index += 2
                continue
            }
            result.append(line)
            index += 1
        }
        return result
    }

    private static func isBareCredentialLabel(_ line: String) -> Bool {
        fold(line).range(
            of: #"^(?:usuario|user|email|senha|password|pass)\s*:?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func deliveryPipeline(in line: String) -> (
        tracker: String, sourceList: String, mergeBranch: String, destList: String
    )? {
        guard let values = captures(
            #"(?i)^usando a skill do ([A-Za-z][A-Za-z0-9_-]*) fa[cç]a a primeira (?:tarefa|task|card) que est[aá] no ([A-Za-z][A-Za-z0-9_-]*) e depois que tiver certeza de que tudo foi feito corretamente de merge para ([A-Za-z][A-Za-z0-9_-]*) garanta que o merge passou e mova para ([A-Za-z][A-Za-z0-9_-]*)\.?$"#,
            in: line
        ), values.count == 4 else { return nil }
        return (values[0], values[1], values[2], values[3])
    }

    private static func isDeliveryBrowser(_ line: String) -> Bool {
        fold(line).range(
            of: #"^use o meu (?:google )?chrome ou computer use se precisar\.?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func deliverySkill(in line: String) -> String? {
        captures(#"(?i)^use\s+(/[A-Za-z][A-Za-z0-9_-]*)\s*\.?$"#, in: line)?.first
    }

    private static func deliveryMustSkill(in line: String) -> String? {
        captures(
            #"(?i)^[eé]\s+obrigat[oó]rio seguir todos os passos da (/[A-Za-z][A-Za-z0-9_-]*) e principalmente os passos envolvendo playwright\.?$"#,
            in: line
        )?.first
    }

    private static func deliveryComment(in line: String) -> (tracker: String, prTool: String)? {
        guard let values = captures(
            #"(?i)^por fim comente no ([A-Za-z][A-Za-z0-9_-]*) card o link da (gh|github) pr\.?$"#,
            in: line
        ), values.count == 2 else { return nil }
        let tool = values[1].lowercased() == "github" ? "gh" : values[1].lowercased()
        return (values[0], tool)
    }

    private static func isDeliveryPostdeploy(_ line: String) -> Bool {
        fold(line).range(
            of: #"^teste sempre depois do deploy(?: feito)?\.?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func deliveryEmail(in line: String) -> String? {
        let values = captures(
            #"(?i)^(?:usuario|user|email)\s*:\s*(\S+@\S+)$"#,
            in: line
        )
        return values?.first
    }

    private static func deliveryPassword(in line: String) -> String? {
        captures(
            #"(?i)^(?:senha|password|pass)\s*:\s*(.+)$"#,
            in: line
        )?.first
    }

    private static func isDeliveryDone(_ line: String) -> Bool {
        fold(line).range(
            of: #"^seu goal so estara completo quando voce tiver certeza de que aplicou todos os passos da [a-z0-9_/-]+ e testou tudo depois do deploy\.?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func deliveryPRTools(in line: String) -> (allowed: String, forbidden: String)? {
        guard let values = captures(
            #"(?i)^estamos usando ([A-Za-z][A-Za-z0-9_-]*) e n[aã]o ([A-Za-z][A-Za-z0-9_-]*)\.?$"#,
            in: line
        ), values.count == 2 else { return nil }
        return (values[0], values[1])
    }

    private static func isSafeSkillAtom(_ value: String) -> Bool {
        value.range(of: #"^/[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    private static func isSafeEmailAtom(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil,
              !containsUnboundSemanticSyntax(value) else {
            return false
        }
        return true
    }

    private static func isSafePasswordAtom(_ value: String) -> Bool {
        !value.isEmpty
            && !containsUnboundSemanticSyntax(value)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !":>(),&=+!@;|?\\".unicodeScalars.contains($0)
            }
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}
