# TODO — Performance do Agent App e dos Bots (auditoria 2026-09-01)

Objetivo do dono: RemoteCode "o mais leve e rápido possível", principalmente ao **trocar de conversa**, **carregar conversa**, **digitar** e **enviar mensagem**. Este arquivo é auto-suficiente para outro agente executar do começo ao fim.

Base: branch `production` @ `e230d0b8` (2026-09-01). Skills usadas na auditoria (AvdLee): swiftui-expert (performance-patterns, state-management, view-structure, list-patterns), swift-concurrency (Task entry isolation, MainActor blocking, actor contention), core-data-expert (princípios aplicados ao SQLite cru: N+1, projeção, índice, save-once), swift-testing-expert.

Detalhes de cada achado (evidência linha a linha, mecanismo de custo, fix sugerido): `audit/perf-gaps-2026-09-01/findings-agentapp.md` (AA-xx), `findings-bots.md` (BT-xx), `findings-chrome.md` (CH-xx). Amostragem de CPU em idle: `audit/perf-gaps-2026-09-01/sample-idle-8s-2026-09-01-summary.md`. Os achados X-xx (transversais) estão descritos só aqui.

## Regras obrigatórias para quem executar

1. Leia `AGENTS.md` §"Loading and perceived performance" e §"Isolated sandbox". Todo trabalho de build/test/run em worktree isolado: `cd "$(scripts/isolated-sandbox.sh ensure)"`. O RemoteCode do dono (`io.remotecode.desktop`, `/tmp/RemoteCode.sock`, porta 18217, `~/Library/Application Support/RemoteCode/remotecode.sqlite`) é intocável.
2. Testes: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Alvo>`. `swift test` completo **não** é verde na base (≈5-7 falhas pré-existentes: model picker ×3, UX copy, perf bundle, testes live-env headless; 26 métodos de `BotsWindowTests` falham por diff de nome). Use baseline-diff: rode o filtro ANTES da mudança, guarde a lista de falhas, compare DEPOIS. Nunca declare "tests pass" sem essa comparação.
3. Cada item de performance precisa (AGENTS.md): teste de regressão do caminho imediato, do término exato, de corrida A→B rápida com rejeição de resultado obsoleto, e de falha; medição antes/depois no mesmo ambiente, ≥5 amostras aquecidas, sem regressão de latência assentada > `max(25 ms, 5%)`.
4. Um commit por item (ou por grupo marcado "juntos"). Mensagem `perf(agent): AA-01 …` / `perf(bots): BT-01 …` / `perf(chrome): CH-01 …` / `perf(db): X-01 …`. Não refatore código adjacente. Não mude schema sem bump em `Schema` + teste de migração.
5. Ferramenta de medição sem Instruments: `sample <pid> 8 1 -mayDie -file out.txt` no app do sandbox (`scripts/isolated-sandbox.sh run`) e agregue símbolos `(in RemoteCode)`; para trocas de thread meça com `os_signpost`/`CFAbsoluteTimeGetCurrent` em torno de `selectThread`→primeiro `objectWillChange` e →fim de `hydrateOpenedThread`. Compare com o build **release** (ver F0).
6. Itens marcados **SAUDÁVEL** nos findings não devem ser reauditados nem "melhorados".
7. Ao terminar um item, marque `[x]` aqui com o hash do commit e o número medido (antes → depois).

## Ordem de ataque (resumo)

| Fase | Fluxo do usuário | Itens | Ganho esperado |
|---|---|---|---|
| F0 | tudo | X-00 build release | maior ganho isolado; pré-requisito para medir o resto |
| F1 | digitar, stream, roster | AA-01, BT-01, X-01 | remove SQLite síncrono do body e do poll de 2 s |
| F2 | trocar/carregar conversa | AA-02+AA-03+AA-04 (juntos), BT-05, BT-12, AA-08+CH-08+CH-09 (juntos), AA-10 | clique→pintura sem fila SQLite; cache de markdown efetivo |
| F3 | digitar/enviar | CH-10, CH-11, AA-13, BT-10, AA-09, BT-07 | 1 layout por tecla; envio sem I/O no main |
| F4 | streaming (por token) | CH-01, CH-02, CH-03, CH-04, AA-05+AA-06 (juntos), BT-02+BT-03+BT-09 (juntos), BT-04, BT-06, CH-05, CH-06, CH-07 | transcript deixa de rebuildar N linhas por token |
| F5 | idle / memória | X-02, X-03, AA-07, BT-08, CH-12, AA-11, AA-12, AA-14, AA-15, AA-16, BT-11, BT-13..BT-17, CH-13..CH-17 | CPU ≈0 em idle; memória limitada |
| F6 | suíte de testes | T-01..T-04 | ciclo de verificação mais rápido para tudo acima |

Severidade: **P0** bloqueia main thread / hang visível; **P1** stutter mensurável ou O(n²)/crescimento sem limite; **P2** desperdício menor.

---

## F0 — Pré-requisito

- [x] **X-00 · P0 · tudo — o app em uso é um build DEBUG (`-Onone`).**
  Evidência: `dist/RemoteCode.app/Contents/MacOS/RemoteCode` tem 216.801.712 bytes, mesmo minuto (2026-08-31 16:02/16:03) e mesmo tamanho ±64 B de `.build/arm64-apple-macosx/debug/RemoteCode`; `strings` do binário contém 5 caminhos `.build/arm64-apple-macosx/debug/*.bundle` e zero `release/`; o último release (`.build/arm64-apple-macosx/release/RemoteCode`, 2026-08-20) tem 121 MB. `scripts/package-app.sh` usa `CONFIG="${RC2_CONFIG:-release}"` — alguém empacotou com `RC2_CONFIG=debug` ou copiou o binário debug. Diffing do SwiftUI, `JSONDecoder` e `AttributedString(markdown:)` são 5-20× mais lentos em debug; isso amplifica TODOS os itens abaixo.
  Fazer: (a) reempacotar release: `RC2_CONFIG=release scripts/package-app.sh` e reinstalar; (b) adicionar guarda em `package-app.sh` que falha se `CONFIG != release` e o destino for `dist/RemoteCode.app` (o sandbox usa `dist/RemoteCodeDebug.app`, esse pode ser debug); (c) opcional: o app loga no `AppLifecycleRecorder`, no boot, `#if DEBUG "build=debug"` para que triagens futuras vejam isso em 1 linha.
  Verificar: `strings dist/RemoteCode.app/Contents/MacOS/RemoteCode | grep -c '/debug/'` == 0; repetir a amostragem de 8 s em idle e guardar como baseline release em `audit/perf-gaps-2026-09-01/`.
  **FEITO (b9a464b1, código)**: guarda no `package-app.sh` (recusa CONFIG!=release com destino `dist/RemoteCode.app`, inclusive truque de caminho `dist/./RemoteCode.app`; output sobrescrito passa); `AppLifecycleRecorder.beginRun()` grava `build=debug` no boot (#if DEBUG, testado). Pacote release construído e verificado no worktree: 0 caminhos `arm64-apple-macosx/debug/` no binário (auditoria achou 5 no debug), 147.639.424 bytes vs 216.801.712. **Reinstalar no `dist/` do dono exige encerrar o app (pid 39820) — rodar `RC2_CONFIG=release scripts/package-app.sh` no checkout com merge quando o dono encerrar.** Baseline idle release pendente da verificação em lote.

## F1 — SQLite síncrono no body e no poll (P0)

- [x] **AA-01 · P0 · digitar + load + idle — `botStore.list()` (SQLite `performSync`) dentro do body do transcript e a cada tecla.**
  `Sources/Surfaces/AgentAppSurface.swift:13582` (`let mentionBots = vm.mentionableBotsProvider()` no body da coluna do transcript) e `:5040` (`composerSuggestions`, lido pelo body do composer em `:16375`). Provider em `Sources/AppShell/AppCommandRouter.swift:2520-2522` = `context.botStore.list()`; `Sources/Persistence/BotStore.swift:72-84` = `db.performSync` + `decodeBot` para cada um dos 39 bots. Durante um run a mesma fila serial está persistindo stream events → o main thread espera pelo writer a cada tecla e a cada tick de pintura de 33 ms.
  Fazer: cache `[BotDefinition]` no `AppCommandRouter` (ou no VM), invalidado por eventos de bot do `EventBus`/`BotStore` (create/update/delete/hide). O closure devolve o array em memória. Zero SQLite em `body`.
  Verificar: teste em `AgentAppViewModelTests` com um `BotStore` instrumentado que conta `list()` — digitar 20 caracteres e rodar 10 ticks de pintura deve produzir 0 chamadas (hoje ≥30); teste que um bot criado depois aparece nas sugestões após o evento.
  **FEITO (83e388dd)**: `BotStore.listCached()` com revisão monotônica (`botsListRevision`) incrementada por todo write de bot; router serve o cache. Medido por teste: 20 teclas + 10 ticks de pintura → 1 query SQLite (antes ≥30); create/hide/delete/rename/duplicate atualizam a próxima leitura.

- [ ] **BT-01 · P0 · switch + load + digitar + stream + idle — `activeBotCount` faz 2 queries SQLite e é lido 5× por body do roster.**
  `Sources/AppShell/BotsWindow.swift:3520` (`activeBotCount { liveWorkingBots().count }`); `liveWorkingBots()` `:3765-3795` chama `botStore.bots(ids:)` e `botStore.conversationsLinked(to:)` + lock do coordinator; `BotsRosterList.body` lê em `:10080, :10086, :10088, :10091, :10093`; `activeBotsSubtitle/FooterLine` `:3521-3535` mais 3×. O roster rebuilda a cada `objectWillChange` do VM (por token, por tick de 250 ms, por tecla de busca) → ~10 `queue.sync` no main por body.
  Fazer: `@Published private(set) var activeBotCount` recalculado só onde os insumos mudam (`rebuildAttentionStates`, `applyAttentionState`, publish de handoff, `didChangeStatus`/`didFinish`). Mínimo aceitável: calcular `liveWorkingBots()` uma vez por body em `let`.
  Verificar: teste em `BotsWindowTests` com store instrumentado: 50 publishes do VM → 0 queries de roster; count muda quando um run começa/termina.
  **FEITO (7bc5c59f)**: `@Published activeBotCount` recalculado em `refreshActiveBotCount()` — didSet de `bots`/`attentionStateByBot`/`peerHandoffs`/override de threads ativas, `didChangeStatus`/`didFinish` e `reloadActiveBotsScreen`. Medido por teste: 50 publishes com leituras de badge/subtitle/footer → 0 execuções de `liveWorkingBots()` (antes ≥10 queries SQLite/body); count 0→1→0 no início/fim de run.

- [ ] **X-01 · P1 · idle + stream — o poll de 2 s dos Subagents decodifica ~770 recibos JSON (~700 KB) por tick com full scan de `audit_log`.**
  Evidência ao vivo (amostra 8 s, app parado): 384 amostras em `AgentOrchestrationAdmissionReceipt.init(from:)`, 52 em `forEachReceiptRecordUnlocked`, 42 em `receiptsUnlocked(matchingThreadIds:limit:childRecordLimit:)`, 34 em `activityReceipts(scope:…)`. Caminho: `AgentAppSurface.swift:1405` → `loadSubagentActivitySnapshotsOffMainActor` (`:1479`, `Task.detached(.utility)` — off-main, ok) → `AgentOrchestrationRuntime.activityReceipts(threadIds:)` (`Sources/AgentRuntime/AgentOrchestrationRuntime.swift:2270`) → `receiptsUnlocked(matchingThreadIds:)` (`:776-808`) → `DeviceTrustRepository.listAuditLogDetails` (`Sources/Persistence/DeviceTrust.swift:640-668`) com `WHERE action IN (?,?) AND detail LIKE '%uuid%' ORDER BY id DESC LIMIT 512` por thread + `LIKE '%"parentReceiptId"%' LIMIT 256` para filhos. `EXPLAIN QUERY PLAN` = `SCAN audit_log` (tabela sem índice em `action`; 8.060 linhas, 5.176 são recibos, 6,1 MB de JSON, 1.728 casam com `parentReceiptId`). Decodifica até 512+256 recibos de ~914 B a cada 2 s, sob `processTransactionLock` + `readTransaction` na fila SQLite serial — compete com o writer de stream. `receipt(runId:)` (`:889-905`) faz o mesmo scan por chamada e é usado em `AppContext.isNestedAgentWorker` (`:2092`) a cada run terminado.
  Fazer (em ordem, cada um vale sozinho): (1) baixar `childRecordLimit`/headroom no poll UI (64×4=256 filhos por tick é excessivo; o badge mostra ≤6 avatares) e pular o tick quando `countStreamEvents`/`lifecycle` não mudou (já existe `shouldPublishSubagentActivity`, mas ele roda DEPOIS de decodificar); (2) manter um cache em memória `[UUID: AgentOrchestrationAdmissionReceipt]` alimentado por `save/update` no próprio runtime (é o único escritor) e invalidado por revisão, para o poll e para `receipt(runId:)` não tocarem o SQLite; (3) `CREATE INDEX idx_audit_log_action_id ON audit_log(action, id)` (Schema bump + migração) para as leituras restantes, e coluna/índice por `run_id`/`thread_id` se os recibos continuarem em `audit_log` (o ideal é tabela própria `agent_orchestration_receipts(id, run_id, thread_id, parent_receipt_id, lifecycle_updated_at, json)`).
  Verificar: reamostrar 8 s em idle com 1 thread ativa: `AgentOrchestrationAdmissionReceipt.init(from:)` < 10 amostras (hoje 384); teste de contagem de decodes por tick quando nada mudou == 0.
  **FEITO (dbdf007d)**: assinatura append-only `(COUNT, MAX(id))` sobre as duas ações de recibo (indexada pelo schema v82 `idx_audit_log_action_id`) guarda o fetch do poll e o `receipt(runId:)`; childRecordLimit do poll 64→16. Medido por teste: 10 ticks idle → 0 decodes (antes ~770/tick); write → próximo poll atualiza (1→2 recibos); `receipt(runId:)` repetido → 0 decodes. **Reamostra 8 s em idle (sandbox, DB do dono copiado, build DEBUG com fixes): `AgentOrchestrationAdmissionReceipt.init(from:)` = 0 amostras (era 384)** — ver `audit/perf-gaps-2026-09-01/sample-idle-8s-sandbox-postfixes-2026-09-01.md`.

## F2 — Trocar e carregar conversa

- [x] **AA-02 + AA-03 + AA-04 · P1 · switch + load — abrir thread = 8-10 leituras SQLite síncronas + replay CPU no MainActor, incluindo TODOS os patches de checkpoint.** (fazer juntos)
  `hydrateOpenedThread` `AgentAppSurface.swift:2266-2416`: `hasRecoverableContext` (2275), `latestStreamEvents` (2296, decode JSON do hot replay no main), `hotReplayIsPartial` = 3 queries (2297), `timelineByReplaying` síncrono (2307), `rehydrateDurableActiveState/ProposedPlans/PendingCallbacks` (2309-2313), `reloadCheckpoints()` (2318) e `planNotesStore.load` (2392). `reloadCheckpoints` `:2725` → `Repositories.swift:7217-7231` `SELECT … file_snapshots_json, diff_patch, file_diffs_json FROM agent_turn_checkpoints WHERE thread_id=?` — no DB ao vivo essa tabela tem 108 MB para 1.096 linhas (~100 KB/linha); tudo decodificado e depois `checkpointDiffPreview` (`@Published String`, 2741-2747) é montado mesmo com o painel fechado; 7 call sites incl. `softReselectOpenThread` (3462). `selectThread` `:2041-2200` ainda faz `draftRepo.upsert` (2099, escrita), `queuedMessageRepo.list` (2135) e `runStartedAt` (2149) ANTES do primeiro publish.
  Fazer: um único loader `Task.detached` "open bundle" (espelhando `loadMessagePageOffMain` `:3662`) que roda todas as queries + `timelineByReplaying` off-main e devolve um struct `Sendable`; main publica uma vez, guardado por geração (como o snapshot diferido em 2335). Checkpoints: listar só metadados (já existe projeção para mobile em `Repositories.swift:7300+`), buscar `diff_patch`/`file_diffs_json` sob demanda quando um checkpoint é selecionado E o painel está visível. `selectThread`: persistir o draft do thread que sai via `persistComposerDraftOffMain` já existente; carregar fila via `flushQueue` do rail hub depois da 1ª pintura; só trabalho em memória antes do publish.
  Verificar: signpost `selectThread`→1º publish < 5 ms com writer ocupado (simule stream persist em paralelo no teste); teste A→B rápido rejeita bundle obsoleto; teste que checkpoint selecionado ainda mostra o patch correto; teste que `agent_turn_checkpoints` blobs não são lidos ao abrir (repo instrumentado).
  **FEITO (58050308)**: bundle "open" único em `Task.detached` (todas as leituras + decode + replay) aplicado em um publish MainActor guardado por geração; reconciliação com o stream (quanta pré-open dropados e contados, re-read durável bornado, eventos buffered aplicam por cima, flag de erro guarda o valor pintado quando mais novo); `selectThread` sem SQLite pré-publish (draft off-main, fila e runStartedAt no bundle, status de fila troca síncrono da memória); checkpoints metadata-only (`listSummaries`) com fetch do diff off-main por seleção e só com o painel visível (hook de abertura). Medido por teste: 0 leituras de blobs ao abrir (antes: tabela inteira); A→B rejeita bundle obsoleto e carrega a fila de B exatamente; 1 linha completa por seleção.

- [ ] **BT-05 · P1 · switch + load — troca fria de bot: ~12 leituras síncronas no main logo após a pintura dest-first.**
  `BotsWindow.swift` `performDeskFreshness` (4563) → `botStore.get` ×2 (4581, 4591/7160), `reloadSelectedBot` (6699) → `restoreDeskMessages` (8150: 4 queries), `restoreDeskWorkLog` (8585), `restoreDeskLiveTurn` (cursor + `latestStreamEvents` com decode completo + `timelineByReplaying`), `reloadStudioSupport` (6533: 7 leituras), `reloadTokenSaverThreadSavings`. `selectDeskThread` (4698) repete o subconjunto.
  Fazer: manter o guard de geração; rodar a fase de leitura em `Task.detached` devolvendo `DeskSnapshot`; aplicar no MainActor se `navigationFreshnessIsCurrent`. `listRecent` primeiro; `reloadStudioSupport` só quando o inspector estiver visível.
  Verificar: primeiro clique/scroll após trocar de bot sem hitch (signpost < 16 ms de main ocupado após a pintura); testes A→B e de término exato.

- [x] **BT-12 · P2 · switch — `reload()` chama `reloadSelectedBot` duas vezes por remontagem** (`BotsWindow.swift:3951` e `:3956`). Pular a 2ª quando bot e conversa selecionados não mudaram após `reloadFleet`.
  **FEITO (35f640c1)**: a 2ª chamada só roda quando bot ou conversa selecionada mudaram. Medido por teste: reload com mesmo bot+conversa → 1 `reloadSelectedBot` (antes 2); após trocar de bot → 1.

- [x] **AA-08 + CH-08 + CH-09 · P1 · load + switch — cache de markdown pequeno demais, chaveado por texto inteiro, e `selectableProse` nunca cacheado.** (juntos)
  **FEITO (8135b67e)**: NSCache 4 MiB / 512; chave por hash; selectableProse por grupo; 48 KiB só no live `cache:false`. Teste: 60 KiB finished → 2ª parse = 0 computes.
  `Sources/Surfaces/AgentMessageMarkdown.swift:44-60`: orçamento total 128 KiB (blocos) + 128 KiB (inline), `countLimit 128`, `maxCachedTextUTF8Bytes = 48 KiB` (`:50`, `:86-88` recusa mensagens finalizadas maiores). Chave `text as NSString` re-hasheada por body (`:91-92`, `:340-341`). `selectableProse` (`:127-172`) concatena um `AttributedString` novo por grupo por body (`:611`) mesmo com hits no cache. Resultado: uma thread com 3 respostas médias já evita tudo ao trocar de conversa; respostas > 48 KiB reparseiam a cada body.
  Fazer: orçamento de alguns MB (os `NSTextView`s já mantêm esses `AttributedString`s vivos); chave por hash de 64 bits pré-computado no modelo da mensagem (`messageId`+`utf8Count`); cachear o resultado de `selectableProse` por grupo; manter a regra de 48 KiB só para `cache:false` (linha viva).
  Verificar: teste que abrir uma thread com 5 respostas de 60 KiB duas vezes reparseia 0 blocos na 2ª; medir tempo do primeiro body após `selectThread` antes/depois.

- [x] **AA-10 · P2 · load — `loadAllMessages` faz 4 round-trips `Task.detached` sequenciais** (`AgentAppSurface.swift:3548-3565`, closures em 3667/3684/3698/3712). Um closure detached que roda as 4 queries e devolve um struct; um hop de volta.
  **FEITO (258c99c7)**: `AgentMessagePagePayload` reúne página + 3 lookups em UM round-trip (também no `loadOlderMessages` e no callback de wire-translation). Teste de hidratação de wire atualizado para exercitar o payload (caminho de produção); 65 testes verdes nas suítes afetadas.

## F3 — Digitar e enviar

- [ ] **CH-10 · P1 · digitar — composer força `ensureLayout` em todo update do SwiftUI e 2× por tecla.**
  `Sources/Surfaces/AgentComposerTextEditor.swift:135` (`updateNSView` chama `recalculateHeight()` incondicionalmente → `:262-266` `ensureLayout` + `usedRect`), `:196-200` (`textDidChange` seta `text` e chama `recalculateHeight()` de novo), `:268` publica altura em `DispatchQueue.main.async` → 3ª passada de body. Qualquer invalidação do pai (token durante digitação) também força layout.
  Fazer: em `updateNSView`, chamar `recalculateHeight()` só quando `applyExternalText` rodou ou a largura mudou; manter a chamada única em `textDidChange`.
  Verificar: teste do representable contando `recalculateHeight` por tecla == 1; por update externo sem mudança == 0.
  **FEITO (f22856fc)**: `updateNSView` só relayout quando texto externo foi aplicado ou a largura mudou; `textDidChange` mantém a passada única. Medido por teste (NSTextView real): 1 tecla → exatamente 1 layout; update externo sem mudança → 0; largura mudou → relayout.

- [ ] **CH-11 · P2 · digitar — `AgentChatComposerBar` aloca `suggestions.map(\.id)` e `Array(enumerated())` por body** (`AgentChatTranscriptChrome.swift:552`, `AgentComposerChrome.swift:630`); 12 closures recriadas e reatribuídas ao `NSTextView` por body (`AgentComposerTextEditor.swift:117-125`). Tornar `AgentComposerSuggestion` `Equatable` e observar o array; iterar `indices`.

- [ ] **AA-13 · P2 · digitar — 2 publishes por tecla e sugestões sem memo.** `AgentComposerTextEditor.swift:220, 260` → `vm.composerCursorOffset = $0` (`AgentAppSurface.swift:16380`) publica sem checar igualdade; `composerSuggestions` (`:5031-5040`) recalculado por body (inclui AA-01). Atribuir `cursorOffset` só se mudou; memoizar por `(prompt, cursorOffset, snapshot.id, botsSignature)`.

- [ ] **BT-10 · P2 · digitar — `composerSuggestions` dos Bots faz 2 `stat` no disco por body** (`BotsWindow.swift:7339-7349`: fingerprint de `claudeSlashCatalogRevision` ANTES do TTL de 1 s). Checar TTL primeiro; curto-circuito quando o token do caret não começa com `/` ou `@`.

- [ ] **AA-09 · P2 · enviar — envio faz 6-8 idas ao SQLite (≥4 escritas) e um `loadAllMessages` redundante no main.**
  `AgentAppSurface.swift:7555` `hasAny`, `:7561` `loadAllMessages(tid)` (repagina tudo embora o espelho seja anexado em 7569), `:7567` `exists`, `:7583` `persistThreadConfig` → `draftRepo.upsert` + CAS de routing, `:7660-7672` `status`/`updateStatus`, `:7009` `recordPromptHistory` (JSON + `repo.set`), `:7008` `lastModelStore.remember`.
  Fazer: remover `loadAllMessages` do envio (a linha durável funde por id depois); agrupar as escritas em uma transação detached DEPOIS de pintar o balão otimista.
  Verificar: signpost clique-Enviar→balão pintado < 16 ms com writer ocupado; teste que a mensagem persiste exatamente uma vez.

- [ ] **BT-07 · P1 · enviar — envio dos Bots lê arquivos de memória/skills do disco e escreve SQLite no MainActor antes do run.**
  `BotsWindow.swift:5601` `send()` → `persistUserMessage` (8690, SQLite) → `enqueueSupervisedBotRun` (8989) → `destBrainInputs` (8891) → `BotHome.readBootstrapMemory` (`Sources/Persistence/BotHome.swift:218`, lê MEMORY.md + USER + notas de 2 dias); dentro do `Task` (herda MainActor) `prepareSupervisedRun` (8936: 3 escritas), `ownedSkillTexts` (5826 → `BotHome.listOwnedSkills` `:375`, `contentsOfDirectory` + mmap de cada SKILL.md) e `BotBrainCompiler.assemble`.
  Fazer: manter o append imediato do balão; coletar memória/skills e montar o brain em `Task.detached` (entradas imutáveis); `MainActor.run` só para `persistDeskTokenSaverUserTranslation` e estado publicado. (Regra da skill: nada antes do primeiro `await` precisa do MainActor → não comece nele.)
  Verificar: teste com `BotHome` apontando para um diretório com 50 skills: main thread ocupado após clicar Enviar < 16 ms.

## F4 — Streaming: parar de rebuildar N linhas por token

- [x] **CH-01 · P0 · load + stream — linhas do transcript carregam `AnyView?`/closures, então o SwiftUI nunca consegue pular o body delas.** (este é o multiplicador de CH-02/03/04/06, AA-14 e BT-09)
  **FEITO (f47714a8)**: Equatable nas linhas (value fields) + `.equatable()` no live turn. Teste: views iguais ignoram closures novas.
  `AgentChatTranscriptChrome.swift:271-272` (`AgentChatUserBubble.header/belowBubble: AnyView?`), `:388` (`AgentChatAssistantReply.content: AnyView?`), `AgentChatLiveTurnChrome.swift:~770` (`AgentChatLiveTurnView.renderFinal: ((String)->AnyView)?`, `afterWork: AnyView?`), `AgentChatSharedChrome.swift:34-40` (`AgentChatThreadRow.onSelect/onStop`). O transcript é `VStack` eager por decisão documentada (`AgentChatTimelineChrome.swift:13-19`, janela de 30 entradas), logo cada uma das ~30 linhas montadas re-executa body a cada token.
  Fazer: `Equatable` em cada view de linha comparando só campos-valor (`text`, `createdAt`, `columnWidth`, `turn`, `live`, ids) + `.equatable()` no ponto de montagem; ou trocar os slots `AnyView?` por parâmetros genéricos `Header: View` com `EquatableView`. Os chamadores (`AgentAppSurface`, `BotsWindow`) já têm os ids para o `==`.
  Verificar: `Self._printChanges()` em `AgentChatUserBubble` durante um stream de 300 deltas: linhas históricas 0 bodies (hoje 300 cada). Teste de snapshot que o conteúdo ainda atualiza quando `text` muda.

- [ ] **CH-02 · P0 · load + stream — `AgentChatUserBubble.body` mede o prompt inteiro com um `NSLayoutManager` novo a cada body.**
  `AgentChatTranscriptChrome.swift:300-304` → `IntrinsicHeightTextView.idealSize` (`AgentLinkedInlineText.swift:~470`) aloca `NSTextStorage`+`NSLayoutManager`+`NSTextContainer(10_000×∞)` e faz `ensureLayout` no prompt completo; sem cache.
  Fazer: cache da largura por `(text, fontSize, bubbleMax)` (NSCache pequeno) ou calcular uma vez no modelo da linha e passar a largura.
  Verificar: contador de `idealSize` por mensagem == 1 durante um stream.
  **FEITO (d2481134)**: `IntrinsicHeightTextView.idealSize` cacheia por (fonte, padding, texto) em NSCache (256 entradas / 1 MiB). Medido por teste: 20 medições do mesmo prompt → exatamente 1 layout; fonte ou texto diferentes medem de novo.

- [ ] **CH-03 · P0 · load + stream — `AgentChatLiveToolRow.body` reexecuta o extrator de diff (2-4 `JSONSerialization` + 2 `split` do output inteiro) a cada body, mesmo para tools que não são diff.**
  `AgentChatLiveTurnChrome.swift` (seção "Tool rows", 1ª linha do body) → `AgentFileEditDiffPresentation.model(for:)` `AgentChatUXPresentation.swift:1082-1330` (`pathFromJSON` ×2, `looksLikeDiff` split ×2, `diffFromJSONChanges`, `synthesizeDiffFromEditJSON`, `parseUnifiedDiff`). `toolInputCache` existe só para input (`AgentAppSurface.swift:10334`).
  Fazer: NSCache de `model(for:)` chaveado por `item.id + state + body.utf8.count + output.utf8.count`; curto-circuito `extractDiffText` por `trimmed.first == "{"/"["` antes de tentar JSON; `looksLikeDiff` com split lazy/limitado.
  Verificar: teste que um tool row Bash com output de 50 KB não-diff faz 0 parses JSON no 2º body.
  **FEITO (d57e62d1)**: `model(for:)` memoizado em NSCache por assinatura de crescimento (id, estado, bytes de body/output, maxLines); `extractDiffText` só tenta JSON quando o payload começa com `{`/`[`; `looksLikeDiff` com split lazy. Medido por teste: 20 passes de um output de 50 KB não-diff → 1 extração (antes 20); crescimento do output e transição de estado re-extraem 1×.

- [ ] **CH-04 · P0 · stream — a linha de markdown em streaming pula o cache na LEITURA também, reparseando todos os blocos a cada token (O(n²)).**
  `AgentChatLiveTurnChrome.swift` (`case .assistantMessage` → `AgentMessageMarkdownView(text:, cacheResults: false)`); `AgentMessageMarkdown.swift:92` e `:341` (`if cache, let cached = …` — com `cache == false` não consulta o cache). Só o último bloco muda entre ticks.
  Fazer: `cache:false` deve significar "não gravar" apenas; sempre ler o cache inline; ou passar `cache:true` para todos os blocos exceto o último. Opcional (fora do chrome): coalescer deltas por frame no VM.
  Verificar: teste que ao streamar 4 KB em 300 deltas, blocos anteriores ao último têm 0 reparses após o 1º.
  **FEITO (50911efe)**: `cache:false` agora significa "não gravar" (a leitura sempre consulta o cache); a view passa `cache:true` para todos os grupos exceto o último da linha viva, e `selectableProse` cacheia todos os blocos do grupo exceto o último. Medido por teste: 10 ticks num grupo vivo de 3 blocos → 10 parses (só o rabo), não 30; testes R4-B de não-gravação seguem verdes.

- [ ] **AA-05 + AA-06 · P1 · switch + digitar + idle — observação do VM inteiro: 78 `@Published` num único objeto rebuildam o `AgentAppView` de 6,8 mil linhas, e os "ReactiveScopes" não impedem pai→filho.** (juntos)
  **PARCIAL (1be74848)**: `focusTick` saiu do VM (PF-12). Composer/transcript já têm reactive scopes. Chrome fields (token saver, git, shells, subagent) ainda publicam no VM de 78 campos.
  `AgentAppSurface.swift:10958` (`@ObservedObject var vm`), `:276-588` (`@Published` de alto churn: `runStartedAt` 515, `statusMessage` 345, `liveBackgroundShellCount/Tasks` 366-370, `subagentActivity` 397, `tokenSaverThread*` 373-380, `gitSummary` 403, `focusTick` 296, `queuedMessages` 509, `checkpoints/checkpointDiffPreview` 492-495). `ComposerReactiveScope`/`TranscriptReactiveScope` (`:217-231`) recebem `content: () -> Content` — o próprio comentário (211-215) admite que o pai recria o wrapper a cada publish. No body do transcript (`:13494-13585`) `paintOrderedTranscriptEntries` ×2, `splitTrailingLiveTurns`, `chatFlowRows` ×2, `makeChatRowPaintContext` (12127-12178, `shouldHideAssistantOutput(previousTurns:)` = O(turnos²) em strings), `activeBotPeerReviewName` (12480-12499) rodam a cada passada; só `transcriptEntries` é memoizado.
  Fazer: coluna do transcript como `View` struct separada com entradas-valor explícitas (`transcriptState`, `status`, `runStartedAt`, `revealCount`, `columnWidth`) e sem closures; publishes só-de-chrome (footer token saver, badge subagentes, contagem de shells, git summary) num `AgentChromeState: ObservableObject` observado apenas pelas strips. Memoizar a tupla derivada `(paintSequence, historyRows, liveRows, paintContext)` chaveada em `(contentGeneration, status, runStartedAt, revealCount, botsSignature)` — mesmo padrão de `transcriptCache`.
  Verificar: `Self._printChanges()` — publish de `tokenSaverThreadSavedTokens` não re-executa o body da coluna do transcript; contagem de `makeChatRowPaintContext` por tick de 33 ms == 0 quando o transcript não mudou.

- [ ] **BT-02 + BT-03 + BT-09 · P1 · stream — `BotsViewModel` com 77 `@Published`: cada token (`deskLiveTimeline = next`, `BotsWindow.swift:8518`) rebuilda root, roster, Active Bots e Schedule Tasks; `deskTimeline` (`:3913-3921` → `BotsDeskFollowThrough.swift:157-300`) refaz merge O(mensagens×turnos) com 5 `sorted` por body; turnos históricos recebem `renderFinal` closure + `AnyView` novos por body (`:11593-11613`, `:11779`).** (juntos)
  Fazer: `BotsDeskLiveState: ObservableObject` (deskLiveTimeline, deskStreamEventCount, deskWorkLog, deskMessages, deskSendInFlight) observado só pelo desk/strip via reactive-scope como o do composer; `BotsRosterState` (publishedRoster, attentionStateByBot, lastPreviewByBot, activeBotCount) só pelo `BotsRosterList`; manter proxies públicos para testes. `deskTimelineItems` e `deskPaintsLiveTurnChrome` cacheados com dirty-flag nos setters de `deskMessages/deskWorkLog/deskLiveTimeline`, recomputados ≤1× por run-loop. Pré-computar `compose(turn)` por turno nos itens memoizados e passar como valor; `AgentChatLiveTurnView` `Equatable` (`turnId, items.count, finished, live, flags`) + `.equatable()`.
  Verificar: `_printChanges()` do roster durante stream == 0; contador de `BotsDeskFollowThrough.timeline` por token == 1 (hoje ≥3); os 26 testes de `BotsWindowTests` que já falham por nome continuam sendo os mesmos (baseline-diff).

- [x] **BT-04 · P1 · stream + idle-com-run — poll de 250 ms faz 3-4 leituras SQLite síncronas no main por tick, redundante com o push.**
  **FEITO (a7ef0c8c / PF-04)**: fallback 2 s; skip enquanto o push está fresco.
  `BotsWindow.swift:8562-8583` (`startDeskLiveTurnWatch`: `streamEventCursor` → `runRepo.streamEventCursor` `AgentRunCoordinator.swift:5287`, `linkedRun` → `runRepo.latestActive` 8620, `refreshPublishedIdentity` → `botStore.get` 7160; `Task` herda MainActor). O push `runCoordinator(didReceive:)` (9920) já aplica cada evento.
  Fazer: reconciliação por evento (`didChangeStatus`/`didFinish`, mudança de `deskTimelineRejoinToken`) + fallback lento de 2 s; leituras em `Task.detached`, hop ao MainActor só para atribuir.
  Verificar: contador de queries por segundo durante stream == 0 fora de transições.

- [ ] **BT-06 · P1 · stream + switch + digitar — rail de threads ordena/filtra e copia o Set de threads ativas 3+N vezes por body** (`BotsWindow.swift:11866-11895`, `:4636-4650`, `:11905`). Calcular `live` e `rows` uma vez no topo de `deskThreadRail` e passar `running` para `deskThreadRow`; ou cachear `filteredDeskConversations` invalidado por `conversations`/query/status.

- [x] **CH-05 · P1 · load + stream — `AgentChatLiveTurnView.body` compõe o turno 2× por body com `contains` O(k²)**
  **FEITO (f47714a8)**: `shouldRenderFinalMessage` reusa a composição do body. (`AgentChatLiveTurnChrome.swift` seção "Turn": `compose(turn)` + `workBlocks` e depois `shouldRenderFinalMessage(turn)` chama `compose` de novo; `deduplicatedAssistantItems`/`assistantTextsMatch` `:167-172`). Reusar a composição; hoistar para turnos finalizados no modelo da linha (`AgentCompletedWorkBlockGrowth` em `AgentChatUXPresentation.swift:927+` já existe e não é usado aqui).

- [x] **CH-06 · P1 · load + stream — header do `AgentChatToolGroupRow` re-deriva `AgentTimelineItemPresentation.make(for:)` para todos os membros por body**
  **FEITO (f47714a8)**: `toolGroupSummary` memoizado por identidade dos membros. (`toolGroupSummary`; `AgentAppSurface.swift:9896-9920` faz `replacingOccurrences` + trim). Pré-computar o summary ao montar o bloco ou memoizar por `(id, streamingCount, failedCount, items.count)`. Nota: `AgentChatLiveToolRow.standardBody` chama `AgentTimelineItemPresentation.*` 6× por body (`AgentAppSurface.swift:9896-10470`) — mesma correção.

- [x] **CH-07 · P1 · stream + load + resize — `AgentLinkedInlineTextRepresentable` calcula o dirty-plan 2× por update com `AttributedString ==` completo**
  **FEITO (82af6460)**: fingerprint antes de `AttributedString ==`. (`AgentLinkedInlineText.swift:230-247`, `:150`). Comparar primeiro `(sourceText, styleKey)`; `AttributedString ==` só como fallback; pular `apply` em `updateNSView` quando `sizeThatFits` já aplicou o mesmo `next` na mesma transação (token de transação).

## F5 — Idle e memória

- [x] **X-02 · P1 · idle — lista de threads recarregada em idle com 2 parses ISO8601 + decode de routing JSON por linha.**
  **FEITO (daace020 + 031f0538)**: índice v83; `unixepoch()` na list; `didChangeStatus` não relista.
  Amostra idle: 36 amostras em `AgentThreadRepository.list(workspaceId:)`, 47 em `LockedISO8601Formatter.date(from:)`, 26 em `parseDate`. `Sources/Persistence/Repositories.swift:862-930`: `ORDER BY t.updated_at DESC` sem índice em `(workspace_id, updated_at)` (só `idx_agent_threads_workspace`) + `parseDate` ×2 + `decodeRoutingConfiguration` por linha, 301 threads no DB ao vivo. Descobrir o chamador em idle (candidatos: `AgentAppSurface.swift:1182/1301` via `AgentWorkspaceRailReloadCoordinator`, `SidebarView.swift:830`) — instrumente `durableListCountForTesting` e registre quem dispara com o app parado.
  Fazer: (1) não recarregar a lista quando nenhum evento de thread ocorreu (gate por revisão/EventBus); (2) `CREATE INDEX idx_agent_threads_workspace_updated ON agent_threads(workspace_id, updated_at DESC, id DESC)` (Schema bump); (3) datas: manter `TEXT` mas parsear lazy ou usar `unixepoch` na query.
  Verificar: reamostra idle sem `AgentThreadRepository.list`; `EXPLAIN QUERY PLAN` usa o índice.

- [ ] **X-03 · P2 · idle — retry de durabilidade terminal em loop de 100 ms para runs presos.**
  `Sources/AgentRuntime/AgentRunCoordinator.swift:8123-8149` (`scheduleTerminalDurabilityRetry`: `Task.detached` + `sleep 100 ms` + `handle(.finished)`); rearmado em `:4223`, `:7410` (flush de stream falhou 2×) e `:7429` (`persistTerminalGraph` falhou) — sem backoff nem teto. Na amostra idle apareceram 41 amostras em `AgentRunCoordinator.handle(event:…)` e 6 no closure do retry; o DB tem um run `running` desde `2026-09-01T00:56:59Z` (id `2E275F0C-…`, thread `47EABEF1-…`) — provável alvo do loop. Cada retry que chega ao caminho de run terminado chama `isNestedAgentWorker` → scan completo de `audit_log` (X-01). O erro `run.terminal_graph.commit` vai para `emitPersistenceIssue`, que não aparece no unified log (`log show` retornou 0 linhas para o processo) — verifique onde ele é gravado antes de concluir a causa.
  Fazer: backoff exponencial (100 ms → 5 s) com teto de tentativas e depois marcar o run `failed` com `error_message` explícito (hoje há 51 runs `failed/interrupted` com `error_message NULL` no DB); registrar o motivo via `AppLifecycleRecorder`.
  Verificar: teste de unidade que um `persistTerminalGraph` que falha sempre produz ≤ N tentativas e termina o run com mensagem; reamostra idle sem `handle(event:)`.

- [x] **AA-07 · P1 · memória — `paintedTimelineByThread` cresce sem limite na sessão**
  **FEITO (031f0538)**: LRU ≤3; limpa no dispose e em deletes. (`AgentAppSurface.swift:2017`, escrito em 2100/2415, nunca removido nem limpo em `dispose()` 1081-1150). LRU ≤3 timelines (ou só threads com run ativo); remover em `applyAuthoritativeThreadDeletions`.

- [x] **BT-08 · P1 · idle — cada `BotsViewModel` (um por janela Bots) recarrega a tela Active Bots inteira a qualquer mudança de status de run, mesmo oculta**
  **FEITO (a7ef0c8c / PF-04)**: `reloadActiveBotsScreen` é no-op fora do destino Active Bots. (`BotsWindow.swift:9953-9973` → `reloadActiveBotsScreen` 3743 → `listRecentFinished(limit: 200)` etc.; sem guard `screen == .activeBots`, ao contrário de `reload()` 3960). Guardar por destino e coalescer por run-loop.

- [x] **CH-12 · P2 · idle — `TimelineView(AgentChatElapsedTickSchedule)` ignora `mode == .lowFrequency`** (`AgentChatLiveTurnChrome.swift` "Working status", `AgentChatSharedChrome.swift:895`). Devolver cadência de 5 s em low-frequency / janela ocluída.
  **FEITO (34ed4411)**: o schedule fixa a cadência de 5 s quando `mode == .lowFrequency`. Medido por teste: modo normal no 1º minuto → 1 s; lowFrequency → 5 s.

- [x] **AA-11 · P2 · load — loops de rehydrate chamam `timeline.apply` por registro, cada um disparando o didSet O(turnos)**
  **FEITO (031f0538)**: aplica numa cópia local e atribui uma vez. (`AgentAppSurface.swift:3478-3480`, `3486-3506`, `3517`). Copiar para local, aplicar tudo, atribuir uma vez.
- [x] **AA-12 · P2 · switch + idle — `reloadTokenSaverThreadSavings` re-soma bytes de todas as mensagens no main**
  **FEITO (031f0538)**: soma UTF-8 no Task off-main. (`:1919-1922`, 6 call sites). Somar no Task off-main ou manter total incremental no didSet de `messages`.
- [x] **AA-14 · P2 · load + idle — `AgentChatLiveTurnView` montado com closures novas por linha em `AgentAppSurface.swift:15238-15259`**
  **FEITO (f47714a8)**: `.equatable()` no chamador; Equatable ignora closures.; `turnRenderCache` (12845-12860) não memoiza a composição. Coberto pela correção de CH-01/CH-05; só confirmar no lado do chamador.
- [x] **AA-15 · P2 · idle — rail deriva estado running e subtítulo por linha por passada**
  **FEITO (031f0538)**: `runningThreadIds` + `now` uma vez no LazyVStack. (`:13109-13125`, `trackedRunId` 5291-5294, `activeThreadCount` 3882). `runningThreadIds: Set` + `now` uma vez por passada.
- [x] **AA-16 · P2 · idle — `hasRunningWorkForChrome` varre `messages` e trava o coordinator por consulta**
  **FEITO (031f0538)**: flag no didSet de `messages`. (`:3890-3899`, `7172-7176`; exposto como `AgentAppSurface.isBusy` 18287, pollado pelo host). Flag em didSet de `messages` + Set de runs vivos por callback.
- [ ] **BT-11 · P2** — `TimelineView` envolve o composer inteiro e `AnyView(deskRoutingControls)` é rebuildado a cada tick (`BotsWindow.swift:11966`). Escopar ao `Text` do label; `@ViewBuilder` genérico.
- [ ] **BT-13 · P2** — busca do roster faz `lowercased()` ×4 por bot por tecla (`:3476-3490`). `range(of:options:.caseInsensitive)`.
- [ ] **BT-14 · P2** — `overlayCachedHumanTextOntoPersistedTokenSaverUsers` O(n²) (`:8301-8320`). Dicionário por id.
- [ ] **BT-15 · P2** — `selectedBot` cai em `botStore.get` no body enquanto o id não está em `bots` (`:3472-3474`; lido em 11008, 12132, 12182…). Memoizar o fallback.
- [ ] **BT-16 · P2** — `MacOSLocalUserCatalog.listEligibleUsers()` (`getpwent`) em todo `init` do VM, 3 janelas (`:3111`). Começar vazio; carregar off-main em `refreshAvailableRunAsUsers()` (já ligado a `onAppear` 12015).
- [ ] **BT-17 · P2** — tasks que começam com `sleep` herdando MainActor (`:2914`, `:8562`, `:1842`). `Task.detached`/`@concurrent` para a espera, `MainActor.run` para a mutação.
- [ ] **CH-13 · P2** — `hoveredCode` `@State` dentro de `AgentMessageMarkdownView` invalida a mensagem toda no hover (`AgentMessageMarkdown.swift:587, 770-774`). Subview `CodeBlockView` com seu próprio `@State`.
- [ ] **CH-14 · P2** — `applyingDetectedLinks` O(matches × len) por `String.Index.distance` (`:~420-427`). Cursor monotônico.
- [ ] **CH-15 · P2** — `SubagentIdentityAvatarView` varre `bots` com `BotHandle.normalize` por avatar (`SubagentActivity.swift:~520`, `:1146`, `:200-209`). Dicionário por handle normalizado; `compactAvatarItems` no init.
- [ ] **CH-16 · P2** — `AgentChatAttachmentChips` `ForEach(id: \.self)` (`AgentChatSharedChrome.swift:806`) remonta e cancela a thumbnail quando o struct muda. `id: \.path`.
- [ ] **CH-17 · P2** — `AgentSystemStripPresentation.collapse` `enumerated().sorted` (`AgentChatUXPresentation.swift:54-63`). Desprezível; só se passar por perto.

## F6 — Suíte de testes (skill swift-testing-expert)

Fatos medidos: 1.031 classes `XCTestCase` vs 3 arquivos com `import Testing`; 246 classes de teste inteiras `@MainActor` (serializam a execução); 106 `Thread.sleep` bloqueantes e ~590 `Task.sleep` (20-350 ms) em 129 arquivos = espera por tempo em vez de por condição; 13 arquivos de teste tocam `NSHomeDirectory()`/Application Support/`remotecode.sqlite` reais; `BotsWindowTests.swift` tem 16.028 linhas e `AgentAppViewModelTests.swift` 9.532; `scripts/test-unit.sh` roda `swift test` sem `--parallel`.

- [ ] **T-01** — Substituir `Thread.sleep`/`Task.sleep` de espera por `await` de condição (continuation/`confirmation`, `awaitSubagentActivityRefreshForTesting` e similares já existem no VM) nos 20 arquivos com mais sleeps (`grep -c "sleep" Tests/**/*.swift | sort -t: -k2 -rn | head -20`). Meta: suíte AppShell+Surfaces ≥30% mais rápida, sem flakiness nova.
- [ ] **T-02** — Isolar os 13 testes que tocam o HOME real (lista: `grep -rlE "NSHomeDirectory\(\)|homeDirectoryForCurrentUser|Library/Application Support|remotecode\.sqlite" Tests`) com diretório temporário por teste; hoje eles impedem execução paralela segura e podem ler o DB do dono.
- [ ] **T-03** — Novos testes de performance desta lista em Swift Testing (`@Test`, `#expect`, `.timeLimit`), em arquivos novos (`Tests/SurfacesTests/AgentAppPerfGapTests.swift`, `Tests/AppShellTests/BotsPerfGapTests.swift`), sem `@MainActor` no tipo do suite — só nas funções que tocam UI. Não migre a suíte XCTest existente (fora de escopo).
- [ ] **T-04** — Quebrar `BotsWindowTests.swift` (16 k linhas) por área ao adicionar os testes acima; não mover testes existentes que falham (mantém o baseline reconhecível).

## Fora de escopo / decisões do dono

- Migrar Agent App para `@Observable` (macOS 14+): resolveria AA-05/BT-02 estruturalmente, mas é refatoração grande; só após F1-F4.
- `audit_log` como store de recibos de orquestração (X-01 item 3, tabela própria): mudança de schema com migração de 5 k linhas — pedir aprovação.
- Tabela `agent_turn_checkpoints` com 108 MB (~100 KB/linha de patch): retenção/compactação é decisão de produto; AA-03 só evita ler os blobs ao abrir.
- DB de 1,5 GB com 73% de páginas livres (`freelist_count` 273.265 de 373.424): é o teto projetado de 1 GiB×2 com GC; não fazer `VACUUM` sem decisão do dono.
- Corrigir Codex/Grok hooks ou Token Saver: não é performance de UI.

## Pendente de auditoria

- [ ] Camada Persistence/AgentRuntime (fila `SQLiteDB`, statements, WAL/pragmas, caminho de load do transcript a partir de `agent_stream_events`): o agente dessa parte ainda não entregou; quando `audit/perf-gaps-2026-09-01/findings-persistence.md` existir, incorporar como itens DB-xx na F2/F5.
