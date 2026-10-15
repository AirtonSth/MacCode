import Foundation
import NaturalLanguage

/// Language of one Titio notice message, decided once per message at flush time.
public enum TitioNoticeLanguage: String, CaseIterable, Sendable {
    case ptBR = "pt-BR"
    case en
}

/// What the copy needs to render one notice. Built from a ledger row or a fact.
public struct TitioNoticeRenderItem: Equatable, Sendable {
    public var key: String
    public var kind: TitioNoticeKind
    public var facts: TitioNoticeFacts
    public var actions: [TitioNoticeAction]?
    public var occurredAt: Date

    public init(key: String, kind: TitioNoticeKind, facts: TitioNoticeFacts, actions: [TitioNoticeAction]?, occurredAt: Date) {
        self.key = key
        self.kind = kind
        self.facts = facts
        self.actions = actions
        self.occurredAt = occurredAt
    }

    public init(record: TitioNoticeRecord) {
        self.init(key: record.key, kind: record.kind, facts: record.facts,
                  actions: record.actions?.map(\.action), occurredAt: record.occurredAt)
    }

    public init(fact: TitioNoticeFact) {
        self.init(key: fact.key, kind: fact.kind, facts: fact.facts, actions: fact.actions, occurredAt: fact.occurredAt)
    }
}

/// A composed Titio message.
public struct TitioNoticeComposed: Equatable, Sendable {
    /// Full message body, ending with the ```choices block when there is a card.
    public var text: String
    /// Banner / push / pet / roster body: first line, markdown stripped, max 178 chars.
    public var preview: String
    /// Labeled card options in display order; exactly the options the block shows. Nil = no card.
    public var cardOptions: [TitioNoticeCardOption]?
    /// The ledger key whose `actions_json` holds the card (the block's `notice`).
    public var cardOwnerKey: String?
}

/// Where a forwarded answer went (result lines).
public enum TitioNoticeReplyTarget: Equatable, Sendable {
    case agent(workspace: String?)
    case bot(name: String?)
}

/// Titio's line after an act (§6 "Result lines").
public enum TitioNoticeResult: Equatable, Sendable {
    case approved(workspace: String?)
    case approvedSession(workspace: String?)
    case declined(workspace: String?)
    case answered(answer: String, target: TitioNoticeReplyTarget)
    case armed(target: TitioNoticeReplyTarget)
    case continued(title: String?)
    case rerun(task: String?)
    case alreadyResolved
    case failed(error: String)
}

/// Italic status line appended to the original message when its notice resolves.
public enum TitioNoticeStatus: Equatable, Sendable {
    case approved
    case declined
    case answered
    case elsewhere
    case expired
    case acknowledged
    /// continue / rerun went through (not in the spec table; see `statusLine`).
    case done
    /// The host action threw (not in the spec table; see `statusLine`).
    case failed

    /// Nil for `flap`: a flapping notice was never posted, so there is nothing to rewrite.
    public init?(resolution: TitioNoticeResolution) {
        switch resolution {
        case .approved, .approvedSession: self = .approved
        case .declined: self = .declined
        case .answered, .forwarded: self = .answered
        case .acknowledged: self = .acknowledged
        case .retried: self = .done
        case .elsewhere: self = .elsewhere
        case .expired: self = .expired
        case .failed: self = .failed
        case .flap: return nil
        }
    }
}

/// Deterministic pt-BR / en copy for Titio notices (spec §6, §16). Pure: no
/// clock, locale or database reads; every input is a parameter.
public enum TitioNoticeCopy {
    public static let bannerTitle = "Titio"
    public static let summaryMaxCharacters = 140
    public static let previewMaxCharacters = 178
    /// Minimum recognizer confidence before the user's text decides the language.
    public static let languageConfidenceThreshold = 0.8

    // MARK: Language (§16)

    /// pt-BR or en for one message: the dominant language of the user's most
    /// recent message to Titio; with no usable text (none yet, too short or
    /// ambiguous), the first preferred system language (`pt*` → pt-BR, else en).
    public static func language(lastUserText: String?, preferredLanguages: [String]) -> TitioNoticeLanguage {
        if let detected = detectedLanguage(lastUserText) { return detected }
        return preferredLanguages.first?.lowercased().hasPrefix("pt") == true ? .ptBR : .en
    }

    /// pt-BR / en when the recognizer is confident, else nil.
    public static func detectedLanguage(_ text: String?) -> TitioNoticeLanguage? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.portuguese, .english]
        recognizer.processString(String(text.prefix(2_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= languageConfidenceThreshold else { return nil }
        if best.key.rawValue.hasPrefix("pt") { return .ptBR }
        if best.key.rawValue.hasPrefix("en") { return .en }
        return nil
    }

    // MARK: Compose

    /// One notice as its own message.
    public static func compose(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage, timeZone: TimeZone = .current) -> TitioNoticeComposed {
        let body = body(for: item, language: language, timeZone: timeZone)
        guard let actions = item.actions else {
            return TitioNoticeComposed(text: body, preview: preview(body), cardOptions: nil, cardOwnerKey: nil)
        }
        let options = labeledOptions(actions, language: language, botName: clean(item.facts.botName, max: 80))
        guard options.count >= 2 else {
            return TitioNoticeComposed(text: body, preview: preview(body), cardOptions: nil, cardOwnerKey: nil)
        }
        let block = choicesBlock(
            question: cardQuestion(for: item, language: language),
            options: options.compactMap(\.label),
            notice: item.key
        )
        return TitioNoticeComposed(text: body + "\n\n" + block, preview: preview(body), cardOptions: options, cardOwnerKey: item.key)
    }

    /// A flushed batch: one item uses its single template; two or more become a
    /// digest (failures first, then by time; at most `digestMaxBullets` bullets).
    /// `catchUp` picks the startup opener. Nil for an empty batch.
    public static func composeBatch(_ items: [TitioNoticeRenderItem], language: TitioNoticeLanguage, catchUp: Bool = false, timeZone: TimeZone = .current) -> TitioNoticeComposed? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return compose(first, language: language, timeZone: timeZone) }
        let pt = language == .ptBR
        let ordered = digestOrder(items)
        var lines: [String] = []
        if catchUp {
            lines.append(pt ? "Enquanto o app estava fechado, ficou isso pendente:" : "While the app was closed, this was pending:")
        } else {
            lines.append(pt ? "Enquanto você estava fora, rolou isso:" : "While you were away:")
        }
        let maxBullets = TitioNoticeTiming.digestMaxBullets
        lines += ordered.prefix(maxBullets).map { "• " + digestLine($0, language: language) }
        if ordered.count > maxBullets {
            let extra = ordered.count - maxBullets
            lines.append(pt ? "+\(extra) mais na Atividade" : "+\(extra) more in Activity")
        }
        let firstFailure = ordered.first { $0.kind.isFailure }
        var cardOptions: [TitioNoticeCardOption]?
        if let firstFailure {
            let name = digestTitle(firstFailure, language: language)
            lines.append(pt ? "Se quiser, abro a **\(name)**." : "Want me to open **\(name)**?")
            let open: TitioNoticeAction
            switch firstFailure.kind {
            case .runFailed, .runInterrupted: open = .openThread
            case .botBlocked: open = .openBot
            default: open = .openActivity
            }
            cardOptions = [
                TitioNoticeCardOption(label: pt ? "Abrir \(name)" : "Open \(name)", action: open),
                TitioNoticeCardOption(label: label(for: .openAllActivity, language: language), action: .openAllActivity),
            ]
        }
        let body = lines.joined(separator: "\n")
        guard let cardOptions, let owner = firstFailure else {
            return TitioNoticeComposed(text: body, preview: preview(body), cardOptions: nil, cardOwnerKey: nil)
        }
        let block = choicesBlock(question: pt ? "O que deseja fazer?" : "What should I do?",
                                 options: cardOptions.compactMap(\.label), notice: owner.key)
        return TitioNoticeComposed(text: body + "\n\n" + block, preview: preview(body), cardOptions: cardOptions, cardOwnerKey: owner.key)
    }

    /// The message text for one notice, without any choices block.
    public static func body(for item: TitioNoticeRenderItem, language: TitioNoticeLanguage, timeZone: TimeZone = .current) -> String {
        let pt = language == .ptBR
        let f = item.facts
        let title = clean(f.title, max: 120)
        let ws = clean(f.workspaceName, max: 80)
        let bot = clean(f.botName, max: 80)
        let summary = summaryLine(f.summary)
        let detail = clean(f.detail, max: 200)
        let duration = f.durationMs.map { self.duration(ms: $0, language: language) }
        let wsPt = ws.map { " do **\($0)**" } ?? ""
        let wsNoPt = ws.map { " no **\($0)**" } ?? ""
        let wsEn = ws.map { " in **\($0)**" } ?? ""
        func opener(_ category: OpenerCategory) -> String { self.opener(category, key: item.key, language: language) }

        switch item.kind {
        case .runCompleted:
            if pt {
                let subject = title.map { "a tarefa **\($0)**" } ?? "uma tarefa"
                return "\(opener(.info)) \(subject)\(wsPt) foi concluída\(duration.map { " em \($0)" } ?? "")."
                    + (summary.map { "\nResumo: “\($0)”" } ?? "")
            }
            let subject = title.map { "**\($0)**" } ?? "a task"
            return "\(opener(.info)) \(subject)\(wsEn) is done\(duration.map { " in \($0)" } ?? "")."
                + (summary.map { "\nSummary: “\($0)”" } ?? "")

        case .runFailed:
            if pt {
                let subject = title.map { "a tarefa **\($0)**" } ?? "uma tarefa"
                return "\(opener(.failure)) \(subject)\(wsPt) falhou.\(summary.map { " Última mensagem: “\($0)”" } ?? "") O que deseja fazer?"
            }
            let subject = title.map { "**\($0)**" } ?? "a task"
            return "\(opener(.failure)) \(subject)\(wsEn) failed.\(summary.map { " Last message: “\($0)”" } ?? "") What should I do?"

        case .runInterrupted:
            if pt {
                let subject = title.map { "a tarefa **\($0)**" } ?? "uma tarefa"
                return "\(opener(.failure)) \(subject)\(wsPt) foi interrompida. Quer que eu continue de onde parou?"
            }
            let subject = title.map { "**\($0)**" } ?? "a task"
            return "\(opener(.failure)) \(subject)\(wsEn) was interrupted. Want me to pick it up where it stopped?"

        case .botReply:
            if pt {
                return "O \(bot.map { "**\($0)**" } ?? "Bot") respondeu\(wsNoPt)" + (summary.map { ": “\($0)”" } ?? ".")
            }
            return "\(bot.map { "**\($0)**" } ?? "A Bot") replied\(wsEn)" + (summary.map { ": “\($0)”" } ?? ".")

        case .approval:
            let requestTitle = clean(f.requestTitle, max: 120)
            let code = detail.map { $0.replacingOccurrences(of: "`", with: "'") }
            let codePart = (code == nil || code == requestTitle) ? "" : " (`\(code!)`)"
            if pt {
                return "Preciso que você decida uma coisa\(wsNoPt): o agente\(title.map { " de **\($0)**" } ?? "") quer \(requestTitle ?? "executar uma ação")\(codePart). O que deseja fazer?"
            }
            return "I need you to decide something\(wsEn): the agent\(title.map { " on **\($0)**" } ?? "") wants to \(requestTitle ?? "take an action")\(codePart). What should I do?"

        case .userInput:
            let prompt = clean(f.prompt, max: 200)
            let subject = pt
                ? "O agente\(title.map { " de **\($0)**" } ?? "")\(wsNoPt)"
                : "The agent\(title.map { " on **\($0)**" } ?? "")\(wsEn)"
            let asked = pt
                ? (prompt.map { " perguntou: *\($0)*" } ?? " fez uma pergunta.")
                : (prompt.map { " asks: *\($0)*" } ?? " has a question.")
            switch f.userInputShape {
            case .options:
                return subject + asked + (pt ? " Qual opção?" : " Which option?")
            case .freeText:
                return subject + asked + (pt
                    ? " Toque em Responder aqui que eu repasso sua próxima mensagem."
                    : " Tap Reply here and I'll pass on your next message.")
            case .secret, .multiQuestion:
                let secret = f.userInputShape == .secret
                if pt {
                    return "\(subject) precisa de \(secret ? "um segredo" : "algumas respostas"). Por segurança, responda direto na conversa."
                }
                return "\(subject) needs \(secret ? "a secret" : "a few answers"). For safety, answer in the thread itself."
            }

        case .manualAction:
            let who = bot ?? title
            if pt {
                return "\(who.map { "O **\($0)**" } ?? "O agente") está esperando você fazer algo no Mac\(detail.map { ": \($0)" } ?? ""). Abra a conversa quando puder."
            }
            return "\(who.map { "**\($0)**" } ?? "The agent") is waiting for you to do something on the Mac\(detail.map { ": \($0)" } ?? ""). Open the thread when you can."

        case .botQuestion:
            if pt {
                return "O \(bot.map { "**\($0)**" } ?? "Bot") precisa de você" + (detail.map { ": *\($0)*" } ?? ".")
            }
            return "\(bot.map { "**\($0)**" } ?? "A Bot") needs you" + (detail.map { ": *\($0)*" } ?? ".")

        case .botBlocked:
            if pt {
                return "\(opener(.failure)) o \(bot.map { "**\($0)**" } ?? "Bot") travou\(detail.map { ": \($0)" } ?? "")."
            }
            return "\(opener(.failure)) \(bot.map { "**\($0)**" } ?? "a Bot") got stuck\(detail.map { ": \($0)" } ?? "")."

        case .scheduledFailed:
            let time = clock(item.occurredAt, language: language, timeZone: timeZone)
            if pt {
                return "\(opener(.failure)) a rotina\(title.map { " **\($0)**" } ?? "")\(wsPt) falhou às \(time)."
            }
            return "\(opener(.failure)) scheduled task\(title.map { " **\($0)**" } ?? "")\(wsEn) failed at \(time)."

        case .gitFailed:
            if pt {
                return "\(opener(.failure)) o `git push`\(wsPt) falhou\(f.exitCode.map { " (código \($0))" } ?? "")."
            }
            return "\(opener(.failure)) `git push`\(wsEn) failed\(f.exitCode.map { " (exit \($0))" } ?? "")."

        case .gitCompleted:
            if pt { return "\(opener(.info)) o push\(wsPt) foi feito." }
            return "\(opener(.info)) the push\(wsEn) went through."

        case .scriptFailed:
            if pt {
                return "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) " + (f.exitCode.map { "saiu com código \($0)." } ?? "falhou.")
            }
            return "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) " + (f.exitCode.map { "exited with code \($0)." } ?? "failed.")

        case .scriptCompleted:
            if pt { return "O script\(title.map { " **\($0)**" } ?? "")\(wsPt) terminou bem." }
            return "\(title.map { "Script **\($0)**" } ?? "A script")\(wsEn) finished fine."

        case .transferFailed, .transferCompleted:
            let failed = item.kind == .transferFailed
            if pt { return "A transferência SSH\(title.map { " **\($0)**" } ?? "") \(failed ? "falhou" : "terminou")." }
            return "\(title.map { "SSH transfer **\($0)**" } ?? "An SSH transfer") \(failed ? "failed" : "finished")."

        case .sshDisconnected:
            if pt { return "\(opener(.failure)) a sessão SSH\(title.map { " **\($0)**" } ?? "") caiu sem você pedir." }
            return "\(opener(.failure)) \(title.map { "SSH session **\($0)**" } ?? "an SSH session") dropped unexpectedly."

        case .fileConflict:
            if pt { return "Preciso de você: \(title.map { "**\($0)**" } ?? "um arquivo") foi alterado fora do editor enquanto você editava." }
            return "I need you: \(title.map { "**\($0)**" } ?? "a file") changed outside the editor while you were editing."

        case .serverListenerFailed:
            if pt {
                return "\(opener(.failure)) o servidor do RemoteCode não conseguiu abrir a porta\(f.port.map { " \($0)" } ?? ""). O iPhone pode não conectar."
            }
            return "\(opener(.failure)) RemoteCode's server could not open \(f.port.map { "port \($0)" } ?? "its port"). Your iPhone may not connect."

        case .providerUpdateFailed:
            if pt { return "\(opener(.failure)) a atualização\(title.map { " do **\($0)**" } ?? "") falhou." }
            return "\(opener(.failure)) the \(title.map { "**\($0)** " } ?? "")update failed."

        case .notificationsDenied:
            return pt
                ? "As notificações do sistema estão desligadas para o RemoteCode, então eu só aviso por aqui e no pet."
                : "System notifications are off for RemoteCode, so I'll only tell you here and from the pet."

        case .external:
            let body = clean(f.body, max: 300)
            if pt { return (title.map { "Chegou um aviso: **\($0)**" } ?? "Chegou um aviso.") + (body.map { "\n“\($0)”" } ?? "") }
            return (title.map { "New notice: **\($0)**" } ?? "New notice.") + (body.map { "\n“\($0)”" } ?? "")
        }
    }

    // MARK: Openers

    public enum OpenerCategory: Sendable { case info, failure, decision }

    public static func openers(_ category: OpenerCategory, language: TitioNoticeLanguage) -> [String] {
        switch (category, language) {
        case (.info, .ptBR): return ["Hmm… vi aqui que", "Ó,", "Opa,"]
        case (.info, .en): return ["Hmm, looks like", "Heads up:", "FYI,"]
        case (.failure, .ptBR): return ["Ih,", "Opa,"]
        case (.failure, .en): return ["Uh-oh,", "Heads up:"]
        case (.decision, .ptBR): return ["Preciso que você decida uma coisa"]
        case (.decision, .en): return ["I need you to decide something"]
        }
    }

    /// Rotates by `fnv1a(key) % n`, so a notice reads the same after a restart.
    public static func opener(_ category: OpenerCategory, key: String, language: TitioNoticeLanguage) -> String {
        let options = openers(category, language: language)
        return options[Int(fnv1a(key) % UInt64(options.count))]
    }

    /// 64-bit FNV-1a over the UTF-8 bytes. Stable across runs (unlike `Hasher`).
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: Card

    /// Card option label (§6 "Card option labels"). Provider and Bot options show their own text.
    public static func label(for action: TitioNoticeAction, language: TitioNoticeLanguage, botName: String? = nil) -> String {
        let pt = language == .ptBR
        switch action {
        case .approve: return pt ? "Aprovar" : "Approve"
        case .approveSession: return pt ? "Aprovar nesta sessão" : "Approve for session"
        case .decline: return pt ? "Recusar" : "Decline"
        case let .providerOption(_, text): return text
        case let .botOption(text): return text
        case .continue: return pt ? "Continuar" : "Continue"
        case .rerun: return pt ? "Rodar de novo" : "Run again"
        case .ack: return pt ? "Entendi" : "Got it"
        case .replyHere: return pt ? "Responder aqui" : "Reply here"
        case .openThread: return pt ? "Abrir conversa" : "Open thread"
        case .openBot: return pt ? "Abrir o \(botName ?? "Bot")" : "Open \(botName ?? "Bot")"
        case .openActivity: return pt ? "Ver na Atividade" : "View in Activity"
        case .openAllActivity: return pt ? "Ver tudo na Atividade" : "See all in Activity"
        }
    }

    /// Labels in display order, trimmed and de-duplicated exactly like
    /// `BotChoicesBlock.parse`, so `option_index` on the card maps 1:1 to the stored action.
    public static func labeledOptions(_ actions: [TitioNoticeAction], language: TitioNoticeLanguage, botName: String?) -> [TitioNoticeCardOption] {
        var seen = Set<String>()
        var result: [TitioNoticeCardOption] = []
        for action in actions {
            let text = label(for: action, language: language, botName: botName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            result.append(TitioNoticeCardOption(label: text, action: action))
            if result.count == BotChoicesBlock.maximumOptions { break }
        }
        return result
    }

    /// The ```choices fence with `{"question","options","notice"}` (sorted keys, one line).
    public static func choicesBlock(question: String?, options: [String], notice: String) -> String {
        var object: [String: Any] = ["options": options, "notice": notice]
        if let question { object["question"] = question }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "```choices\n" + (String(data: data, encoding: .utf8) ?? "{}") + "\n```"
    }

    private static func cardQuestion(for item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let pt = language == .ptBR
        let picksAnOption = item.actions?.contains {
            if case .providerOption = $0 { return true }
            if case .botOption = $0 { return true }
            return false
        } ?? false
        if picksAnOption { return pt ? "Qual opção?" : "Which option?" }
        return pt ? "O que deseja fazer?" : "What should I do?"
    }

    // MARK: Digest

    /// Failures first, then the rest; each group by `occurredAt` (key breaks ties).
    public static func digestOrder(_ items: [TitioNoticeRenderItem]) -> [TitioNoticeRenderItem] {
        let byTime: (TitioNoticeRenderItem, TitioNoticeRenderItem) -> Bool = {
            $0.occurredAt == $1.occurredAt ? $0.key < $1.key : $0.occurredAt < $1.occurredAt
        }
        return items.filter { $0.kind.isFailure }.sorted(by: byTime) + items.filter { !$0.kind.isFailure }.sorted(by: byTime)
    }

    /// `**{workspace}** · {title}: {state}{ ({duration})}`.
    public static func digestLine(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let ws = clean(item.facts.workspaceName, max: 80).map { "**\($0)** · " } ?? ""
        let duration = item.facts.durationMs.map { " (\(self.duration(ms: $0, language: language)))" } ?? ""
        return "\(ws)\(digestTitle(item, language: language)): \(digestState(item.kind, language: language))\(duration)"
    }

    static func digestTitle(_ item: TitioNoticeRenderItem, language: TitioNoticeLanguage) -> String {
        let f = item.facts
        let named: String?
        switch item.kind {
        case .botReply, .botQuestion, .botBlocked, .manualAction:
            named = clean(f.botName, max: 80) ?? clean(f.title, max: 120)
        default:
            named = clean(f.title, max: 120)
        }
        if let named { return named }
        let pt = language == .ptBR
        switch item.kind {
        case .runCompleted, .runFailed, .runInterrupted: return pt ? "tarefa" : "task"
        case .botReply, .botQuestion, .botBlocked: return "Bot"
        case .approval, .userInput, .manualAction: return pt ? "pedido" : "request"
        case .scheduledFailed: return pt ? "rotina" : "scheduled task"
        case .gitFailed, .gitCompleted: return "git push"
        case .scriptFailed, .scriptCompleted: return "script"
        case .transferFailed, .transferCompleted: return pt ? "transferência SSH" : "SSH transfer"
        case .sshDisconnected: return pt ? "sessão SSH" : "SSH session"
        case .fileConflict: return pt ? "arquivo" : "file"
        case .serverListenerFailed: return pt ? "servidor" : "server"
        case .providerUpdateFailed: return pt ? "atualização" : "update"
        case .notificationsDenied: return pt ? "notificações" : "notifications"
        case .external: return pt ? "aviso" : "notice"
        }
    }

    static func digestState(_ kind: TitioNoticeKind, language: TitioNoticeLanguage) -> String {
        let pt = language == .ptBR
        switch kind {
        case .runCompleted: return pt ? "concluída" : "done"
        case .runInterrupted: return pt ? "interrompida" : "interrupted"
        case .approval, .userInput, .manualAction, .botQuestion, .fileConflict: return pt ? "precisa de você" : "needs you"
        default: return kind.isFailure ? (pt ? "falhou" : "failed") : "ok"
        }
    }

    // MARK: Result and status lines

    public static func resultLine(_ result: TitioNoticeResult, language: TitioNoticeLanguage) -> String {
        let pt = language == .ptBR
        func ws(_ value: String?, _ ptPrefix: String) -> String {
            guard let value = clean(value, max: 80) else { return "" }
            return pt ? " \(ptPrefix) **\(value)**" : " in **\(value)**"
        }
        func target(_ target: TitioNoticeReplyTarget) -> String {
            switch target {
            case let .agent(workspace):
                return (pt ? "o agente" : "the agent") + ws(workspace, "do")
            case let .bot(name):
                guard let name = clean(name, max: 80) else { return pt ? "o Bot" : "the Bot" }
                return pt ? "o **\(name)**" : "**\(name)**"
            }
        }
        switch result {
        case let .approved(workspace):
            return pt ? "Feito, aprovei\(ws(workspace, "no"))." : "Done, approved\(ws(workspace, "no"))."
        case let .approvedSession(workspace):
            return pt ? "Feito, aprovei para esta sessão\(ws(workspace, "no"))." : "Done, approved for this session\(ws(workspace, "no"))."
        case let .declined(workspace):
            return pt ? "Ok, recusei. O agente\(ws(workspace, "do")) foi avisado." : "OK, declined. The agent\(ws(workspace, "do")) was told."
        case let .answered(answer, to):
            let quoted = clean(answer, max: summaryMaxCharacters) ?? ""
            return pt ? "Repassei “\(quoted)” para \(target(to))." : "Passed “\(quoted)” to \(target(to))."
        case let .armed(to):
            return pt ? "Pode mandar. Eu repasso sua próxima mensagem para \(target(to))." : "Go ahead. I'll pass your next message to \(target(to))."
        case let .continued(title):
            let name = clean(title, max: 120).map { "**\($0)**" }
            return pt ? "Pedi para continuar \(name ?? "a tarefa")." : "Asked \(name ?? "the task") to continue."
        case let .rerun(task):
            let name = clean(task, max: 120).map { "**\($0)**" }
            return pt ? "Rodando \(name ?? "a rotina") de novo." : "Running \(name ?? "the scheduled task") again."
        case .alreadyResolved:
            return pt ? "Isso já tinha sido resolvido ou expirou; não enviei nada." : "That was already handled or expired; I sent nothing."
        case let .failed(error):
            let reason = clean(error, max: 200) ?? (pt ? "erro desconhecido" : "unknown error")
            return pt ? "Não consegui enviar: \(reason). Abra a conversa para decidir por lá." : "I couldn't send it: \(reason). Open the thread to decide there."
        }
    }

    /// `done` and `failed` are not in the spec's status table; they cover
    /// continue/rerun and a host action that threw, so a resolved card never
    /// keeps a stale block.
    public static func statusLine(_ status: TitioNoticeStatus, language: TitioNoticeLanguage, at date: Date, timeZone: TimeZone = .current) -> String {
        let pt = language == .ptBR
        let time = clock(date, language: language, timeZone: timeZone)
        switch status {
        case .approved: return pt ? "_Aprovado por você às \(time)._" : "_Approved by you at \(time)._"
        case .declined: return pt ? "_Recusado às \(time)._" : "_Declined at \(time)._"
        case .answered: return pt ? "_Respondido às \(time)._" : "_Answered at \(time)._"
        case .elsewhere: return pt ? "_Resolvido em outro lugar._" : "_Handled elsewhere._"
        case .expired: return pt ? "_Expirou._" : "_Expired._"
        case .acknowledged: return pt ? "_Visto._" : "_Seen._"
        case .done: return pt ? "_Feito às \(time)._" : "_Done at \(time)._"
        case .failed: return pt ? "_Não deu certo; abra a conversa._" : "_Didn't go through; open the thread._"
        }
    }

    /// The original message with its ```choices block removed and the status line appended.
    public static func resolvedText(original: String, statusLine: String) -> String {
        let parsed = BotChoicesBlock.parse(original)
        let base = trimmedTrailing(parsed.choices != nil ? parsed.text : original)
        if base.hasSuffix(statusLine) { return base }
        return base + "\n\n" + statusLine
    }

    // MARK: Misc copy

    /// The dedicated inbox conversation title.
    public static func inboxTitle(language: TitioNoticeLanguage) -> String {
        language == .ptBR ? "Notificações" : "Notifications"
    }

    /// Label under the stacked notice cards when more than `openNoticeCardsMax` are open.
    public static func openDecisionsLabel(extra: Int, language: TitioNoticeLanguage) -> String {
        language == .ptBR ? "+\(extra) decisões abertas" : "+\(extra) open decisions"
    }

    /// Titio's own replies get only this banner: title "Titio", body = first line of the reply.
    public static func directReplyBanner(replyText: String) -> (title: String, body: String) {
        (bannerTitle, preview(replyText))
    }

    /// First non-empty line, markdown emphasis/code marks stripped, max 178 chars.
    public static func preview(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let stripped = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        return clip(stripped, max: previewMaxCharacters)
    }

    // MARK: Formatting

    /// pt "10,4 s" / "2 min"; en "10.4s" / "2 min"; an hour or more is "1 h 5 min".
    public static func duration(ms: Int, language: TitioNoticeLanguage) -> String {
        let tenths = (Double(max(0, ms)) / 100).rounded()
        if tenths < 600 {
            var number = String(format: "%.1f", tenths / 10)
            if number.hasSuffix(".0") { number.removeLast(2) }
            return language == .ptBR ? number.replacingOccurrences(of: ".", with: ",") + " s" : number + "s"
        }
        let minutes = Int((Double(ms) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// pt "HH:mm", en "h:mm a".
    public static func clock(_ date: Date, language: TitioNoticeLanguage, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .ptBR ? "pt_BR" : "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = language == .ptBR ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    /// One line (newlines and runs of spaces collapsed), trimmed, clipped; nil when empty.
    /// Keeping facts on one line also stops a fact from forging a ```choices fence.
    static func clean(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let flat = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.isEmpty ? nil : clip(flat, max: max)
    }

    /// The summary's first non-empty line, max 140 chars.
    static func summaryLine(_ value: String?) -> String? {
        let first = value?.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return clean(first, max: summaryMaxCharacters)
    }

    static func clip(_ text: String, max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }

    private static func trimmedTrailing(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
