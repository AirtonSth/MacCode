# UX Improvement Plan — RemoteCode Desktop & Mobile

> Auditoria completa de UX para eliminar glitches, flickering, layout shifts, carregamento fora de ordem e micro-interacoes quebradas.

---

## Legenda de Prioridade

- **P0 — Critical**: Problema visivel que quebra o fluxo do usuario (conteudo some, tela pisca, dados perdidos)
- **P1 — High**: Problema perceptivel que causa desconforto (layout shift, flash de estado errado, jank)
- **P2 — Medium**: Problema sutil mas que diminui a sensacao de polimento
- **P3 — Low**: Detalhe cosmetico, so perceptivel se procurar

---

## DESKTOP

### P0 — Critical

- [x] **[D-01] Waterfall de estados vazios no boot** — `App.tsx`
  - `handleBootstrap()` dispara `SET_PROJECTS` → `SET_SELECTED_PROJECT` → effect carrega chats → effect carrega messages. Cada etapa zera o estado anterior, gerando 3-4 repinturas: sidebar vazia → projetos → chat list vazia → chats → messages vazias → mensagens.
  - **Fix**: Carregar projects + chats + messages em uma unica operacao batch e despachar um unico `BOOTSTRAP_COMPLETE` com todos os dados.
  - **Done**: Added `BOOTSTRAP_COMPLETE` reducer action. Tests: `useWorkspaceStore.bootstrap.test.ts` (4 tests pass)

### P1 — High

- [x] **[D-02] `SET_SELECTED_CHAT` apaga streaming state de TODOS os chats** — `useWorkspaceStore.ts:488`
  - Trocar de chat zera `streamingByChat`, `streamHistoryByChat`, etc. para todos os chats (nao so o anterior). Ao voltar, o usuario perde todo o contexto de streaming.
  - **Fix**: Preservar streaming state do chat anterior; limpar apenas o chat que esta sendo deselecionado.
  - **Done**: Removed 6 streaming map resets from SET_SELECTED_CHAT. Tests: `useWorkspaceStore.streaming-preservation.test.ts` (4 tests pass)

- [x] **[D-03] Fade-in de 320ms no layout principal atrasa first paint** — `App.tsx:2611`
  - `motion.div` com `initial={{ opacity: 0, y: 12 }}` e duracao de 320ms mantem o app invisivel durante o bootstrap.
  - **Fix**: Remover ou reduzir a animacao de entrada do shell. Mostrar o layout imediatamente com skeleton states.
  - **Done**: Reduced to 100ms with initial opacity 0.8/y:4. Near-instant first paint.

- [x] **[D-04] `SET_CHATS` sempre auto-seleciona o 1o chat e reseta messageWindow** — `useWorkspaceStore.ts:424`
  - Qualquer refresh da lista de chats (incluindo via WebSocket `chat_created`) reseta a conversa visivel.
  - **Fix**: Preservar `selectedChatId` se ele ainda existir na lista atualizada. So mudar se o chat selecionado foi removido.
  - **Done**: SET_CHATS now preserves selection when chat exists in new list. Tests: `useWorkspaceStore.selection.test.ts` (5 tests pass)

- [x] **[D-05] `UPSERT_CHAT` forca selecao para o chat atualizado** — `useWorkspaceStore.ts:435`
  - Se outro cliente cria um chat, o usuario e arrancado da conversa atual.
  - **Fix**: `UPSERT_CHAT` deve apenas adicionar/atualizar na lista. Selecao automatica so se for resultado de acao explicita do usuario.
  - **Done**: UPSERT_CHAT only changes selection when selectedChatId is null. Tests: `useWorkspaceStore.selection.test.ts` (3 tests pass)

- [x] **[D-06] `collapseTurnItems` fecha itens que o usuario expandiu manualmente** — `useWorkspaceStore.ts:244`
  - Quando um turn completa, TODOS os itens colapsam, mesmo os que o usuario abriu para ler output de tool.
  - **Fix**: Respeitar flag `expandedByUser`. So colapsar itens que foram auto-expandidos.
  - **Done**: `collapseTurnItems` now checks `expandedByUser` before collapsing. User-expanded items keep state "completed" instead of "collapsed". Tests: `useWorkspaceStore.collapse.test.ts` (8 tests).

- [x] **[D-07] Loading states inicializam como `false` causando flash de empty state** — `useWorkspaceStore.ts:1109`
  - `projectsLoading: false`, `chatsLoading: false`, `messagesLoading: false` no initial state. UI mostra "No workspaces yet" por 1 frame antes de mostrar o loading spinner.
  - **Fix**: Inicializar loading states como `true` (ou criar estado "initial" distinto de "idle").
  - **Done**: Initial state now has `projectsLoading: true, chatsLoading: true, messagesLoading: true`. Tests: `useWorkspaceStore.bootstrap.test.ts`

- [x] **[D-08] Layout shift entre empty state / loading / content no ConversationPanel** — `ConversationPanel.tsx:426`
  - Tres estados condicionais com alturas completamente diferentes. Transicao entre eles causa salto visual.
  - **Fix**: Usar skeleton screens que mantenham a mesma estrutura visual do estado final. Ou reservar espaco minimo.
  - **Done**: Added minHeight:200 container + skeleton placeholder with animated pulse bars matching message layout.

- [x] **[D-09] Auto-expand de tool items causa layout jump apos 2s** — `StreamingTimeline.tsx:181`
  - `setTimeout(2000)` expande itens de tool sem animacao. Tudo abaixo pula para baixo.
  - **Fix**: Animar a expansao com `motion.div` (height transition). Considerar nao auto-expandir se o scroll nao esta no bottom.
  - **Done**: Replaced `motion.pre` with `motion.div` wrapper + `overflow: hidden` + Material cubic-bezier easing (0.25s). Tests: `StreamingTimeline.test.ts` (6 tests).

- [x] **[D-10] Items colapsam abruptamente quando completam** — `StreamingTimeline.tsx:808`
  - Itens auto-expandidos colapsam instantaneamente quando `state` muda de "running" para "completed".
  - **Fix**: Manter expandido por default quando completa. Ou animar o colapso. Respeitar `expandedByUser`.
  - **Done**: Added 600ms delayed auto-collapse for non-user items on running→completed transition. User-expanded items never auto-collapse.

- [x] **[D-11] Terminal auto-scroll ignora posicao do usuario** — `ThreadTerminalPanel.tsx:44`
  - `useEffect([items])` sempre rola para o bottom. Impossivel ler output anterior durante streaming.
  - **Fix**: Checar se o usuario esta no bottom (similar ao `isAtBottomRef` do ConversationPanel). So auto-scroll se estiver.
  - **Done**: Added isAtBottom check with 48px threshold. Tests: `ThreadTerminalPanel.test.ts` (12 tests pass)

- [x] **[D-12] Terminal panel abre/fecha causando layout shift de 42vh** — `App.tsx:3190`
  - Toggle do terminal insere/remove um div de `42vh min-h-[220px]`. A area de conversa encolhe dramaticamente.
  - **Fix**: Animar a abertura/fechamento. Ou usar um painel resizable com drag handle.
  - **Done**: Wrapped in `AnimatePresence` + `motion.div` with height 0→auto animation, `overflow-hidden`, 0.3s cubic-bezier. Respects reduced motion. Tests: `TerminalPanelAnimation.test.ts` (6 tests).

- [ ] **[D-13] Google Fonts import bloqueia render (FOUT)** — `index.css:1`
  - `@import url("fonts.googleapis.com/...")` e render-blocking. Texto renderiza em fonte fallback, depois pula para Manrope.
  - **Fix**: Preload as fontes no HTML (`<link rel="preload">`), ou hospedar localmente, ou usar `font-display: optional`.

### P2 — Medium

- [ ] **[D-14] Provider switch causa flash de "No models"** — `App.tsx:2126`
  - `setSelectedModel(null)` + `setAvailableModels([])` executam antes do fetch. Dropdowns ficam vazios por 200-500ms.
  - **Fix**: Manter modelos do provider anterior visiveis ate os novos carregarem. Ou mostrar skeleton no dropdown.

- [x] **[D-15] Sem skeleton screen no sidebar** — `App.tsx:2679`
  - "Loading workspaces..." como texto simples, depois pula para lista completa.
  - **Fix**: Skeleton cards na sidebar matching o layout final.

- [x] **[D-16] Double dispatch em `handleSelectProject`** — `App.tsx:2212`
  - `dispatch(SET_SELECTED_CHAT, null)` seguido de `dispatch(SET_SELECTED_PROJECT, id)` causa render intermediario com "No chat selected".
  - **Fix**: Despachar uma unica action `SELECT_PROJECT` que limpa e seleciona atomicamente.

- [ ] **[D-17] Message window de 5 mensagens e muito agressivo** — `useWorkspaceStore.ts:269`
  - `MESSAGE_WINDOW_PAGE_SIZE = 5`. Mensagens antigas desaparecem quando novas chegam.
  - **Fix**: Aumentar para 20-30. Ou implementar virtualizacao (react-window/virtuoso).

- [ ] **[D-18] Scroll-to-bottom briga com scroll do usuario** — `ConversationPanel.tsx:353`
  - `useLayoutEffect` com `isAtBottomRef` threshold de 24px. Durante streaming, qualquer scroll perto do bottom e capturado.
  - **Fix**: Aumentar threshold. Ou pausar auto-scroll quando o usuario inicia scroll manual (e mostrar botao "Scroll to bottom").

- [ ] **[D-19] AnimatePresence causa shimmer ao trocar de chat** — `ConversationPanel.tsx:508`
  - Mensagens animam saida e entrada quando o chat muda. Parece "shimmer" visual.
  - **Fix**: Desabilitar animacao exit/enter no switch de chat. Animar apenas novas mensagens adicionadas.

- [ ] **[D-20] Top pagination re-triggers sem debounce** — `ConversationPanel.tsx:311`
  - Scroll perto do topo (<=32px) dispara load imediato. O guard reseta quando messages mudam, re-triggering.
  - **Fix**: Adicionar debounce de ~300ms. Manter guard ativo ate o scroll sair da zona de trigger.

- [x] **[D-21] Textarea double-reflow por keystroke** — `MessageComposer.tsx:242`
  - `height = "auto"` -> reflow -> `height = scrollHeight` -> reflow. Duas forced layouts por tecla.
  - **Fix**: Usar `scrollHeight` sem resetar para `"auto"` primeiro. Ou usar `ResizeObserver`.

- [x] **[D-22] Three.js canvas: flash de nada antes do WebGL** — `ChatEmptyBackground.tsx:22`
  - `ready=false` -> retorna `null` por 1 frame. Depois inicializa WebGL (50-200ms de stutter).
  - **Fix**: Mostrar fallback estatico (gradiente CSS) enquanto WebGL carrega. Fade-in o canvas.

- [x] **[D-23] Pointer listener no Three.js causa re-renders excessivos** — `ChatEmptyBackground.tsx:28`
  - `setPointer` em cada `pointermove` (60fps). React re-renderiza o componente inteiro.
  - **Fix**: Usar `useRef` para armazenar pointer position. Passar para Three.js scene via ref, nao state.
  - **Done**: Replaced useState with useRef. Scene reads pointerRef.current in useFrame. Tests: `ChatEmptyBackground.test.ts` (3 tests pass)

- [ ] **[D-24] `prefers-reduced-motion` mata TODAS as animacoes** — `index.css:149`
  - `animation-duration: 0.001ms !important` em tudo. Transicoes funcionais (resize, dropdown) tambem somem.
  - **Fix**: Ser seletivo. Manter transicoes de layout e opacity. So remover animacoes decorativas.

### P3 — Low

- [x] **[D-25] Spinner flash em `openingProjectId`** — `App.tsx:2261`
  - Loader aparece por ~1 frame se a API responder rapido. Adicionar delay minimo (150ms) para exibir spinner.

- [x] **[D-26] "Working..." indicator pisca em turns rapidos** — `ConversationPanel.tsx:573`
  - Fade-in -> imediato fade-out quando `isWorking` flipa rapido. Usar debounce para mostrar.

- [x] **[D-27] State badges mudam sem transicao** — `StreamingTimeline.tsx:237`
  - Cor e texto snappam de "running" (azul) para "completed" (verde). Adicionar transition CSS.
  - **Done**: Added `transition-all duration-200` to badge span.

- [x] **[D-28] Shimmer text "materializa" ao completar** — `StreamingTimeline.tsx:231`
  - `color: transparent` -> `color: normal` em 1 frame. Usar fade transition.
  - **Done**: Added `transition: color 0.3s ease` to `.loading-shimmer-pure-text`.

- [ ] **[D-29] Status text do composer muda abruptamente** — `MessageComposer.tsx:262`
  - Texto alterna entre estados sem transicao. Usar crossfade.

- [x] **[D-30] Send button muda cor abruptamente** — `MessageComposer.tsx:433`
  - Cinza -> vermelho instantaneo. Usar `transition-colors`.
  - **Done**: Added `transition-colors duration-200` to send/stop button.

- [ ] **[D-31] Git branch dropdown sem animacao** — `GitBranchControl.tsx:171`
  - Pop-in/pop-out instantaneo. Usar AnimatePresence ou CSS transition.

- [ ] **[D-32] Branch items flash disabled durante checkout** — `GitBranchControl.tsx:89`
  - Botoes ficam disabled por ~1 frame antes do dropdown fechar.

- [ ] **[D-33] Mensagem persistente "Not a git repository"** — `GitBranchControl.tsx:307`
  - Texto de erro sempre visivel para projetos non-git. Considerar ocultar ou usar tooltip.

- [x] **[D-34] Shimmer animation usa `steps(48)`** — `index.css:122`
  - Shimmer fica choppy/pixelado. Considerar usar `linear` ou `ease` para smooth sweep.
  - **Done**: Changed `steps(48, end)` to `linear` for smooth shimmer.

---

## MOBILE

### P0 — Critical

- [x] **[M-01] WebSocket reconecta a cada mudanca de identidade do `handleServerEvent`** — `use-workspace-shell.ts:1795`
  - `handleServerEvent` esta nas deps do effect que cria o WS client. Como `handleServerEvent` e recriado frequentemente (depende de muitos callbacks/state), o WS e destruido e recriado repetidamente. Conexao cai e reconecta causando flicker no estado de conexao e possivel perda de mensagens.
  - **Fix**: Mover `handleServerEvent` para um `useRef` e acessar `.current` dentro do effect. Remover da dependency array.
  - **Done**: Added `handleServerEventRef` and `handleConnectionStateChangeRef`. Effect deps reduced to `[config.activeTarget, isActive]`. Tests: `ws-reconnect-stability.test.ts` (2 tests pass)

- [x] **[M-02] Streaming text desaparece antes da mensagem final carregar (gap de ate 1.25s)** — `use-workspace-shell.ts:1495`
  - No `assistant_done`, streaming text e zerado imediatamente. O retry loop (`trySyncMessages`, 5x com 250ms) tenta buscar a mensagem persistida. Durante esse gap, o usuario ve a resposta sumir.
  - **Fix**: Manter streaming text visivel como fallback ate a mensagem final chegar. So limpar apos confirmacao do fetch.
  - **Done**: `clearStreamingText()` now called only inside `trySyncMessages` at each exit point. Tests: `streaming-text-persistence.test.ts` (4 tests pass)

### P1 — High

- [ ] **[M-03] 11+ useState independentes causam render cascade por evento WS** — `use-workspace-shell.ts:474`
  - Cada `setState` trigga um re-render separado. Em `handleServerEvent`, varios sao chamados em sequencia, gerando 3-5 re-renders por evento.
  - **Fix**: Consolidar em `useReducer`. Ou usar `React.unstable_batchedUpdates` (React 18+ ja batcheia, mas verificar se funciona com callbacks assincronos no RN).

- [x] **[M-04] Switch de chat causa cascata de 10+ state updates e query removals** — `use-workspace-shell.ts:690`
  - Remove queries, limpa 5+ states, seta novos valores. Gera frames intermediarios com UI vazia.
  - **Fix**: Fazer toda a limpeza/setup em uma unica transicao atomica. Ou manter dados do chat anterior ate os novos estarem prontos (cross-fade).
  - **Done**: Deferred query removal via `queueMicrotask` + wrapped `selectChatById` state updates in `startTransition`. Tests: `use-workspace-shell.chat-switch.test.ts` (10 tests).

- [x] **[M-05] Foreground handler dispara 5+ query invalidations simultaneas** — `use-workspace-shell.ts:1825`
  - App volta do background -> invalida activeThreads, chats, chatContext, messages + syncMissedEvents. Respostas chegam em tempos diferentes, UI "se acomoda" por 0.5-2s.
  - **Fix**: Agrupar invalidacoes. Ou usar flag `isRestoringFromBackground` para mostrar um overlay suave durante a sincronizacao.
  - **Done**: Batched all refetches into `Promise.all` with `isRestoringFromBackground` flag. Flag resets in `.finally()`. Tests: `use-workspace-shell.foreground-restore.test.ts` (8 tests).

- [x] **[M-06] Delay na criacao de chat ao enviar mensagem** — `use-workspace-shell.ts:2230`
  - `sendMessage` em thread vazia precisa `await createChat()` antes de mostrar a mensagem otimista. Delay perceptivel entre pressionar "Send" e ver a mensagem.
  - **Fix**: Mostrar mensagem otimista imediatamente com ID temporario. Substituir pelo ID real quando a criacao completar.

- [ ] **[M-07] 40+ useState no chat-screen.tsx** — `chat-screen.tsx:166`
  - Componente re-renderiza inteiro em qualquer mudanca de estado. Keyboard input pode laggear.
  - **Fix**: Extrair sub-componentes memoizados (drawer, terminal, modais). Ou usar `useReducer` para estado local.

- [x] **[M-08] Banner de active threads causa layout shift** — `chat-screen.tsx:1362`
  - Banner aparece/desaparece baseado em poll de 2.5s. Toda a area de mensagem pula 30-40px.
  - **Fix**: Reservar espaco fixo para o banner. Ou anima-lo com height transition. Ou posicionar como overlay.
  - **Done**: Converted banner to absolute overlay with fade animation (200ms). Always renders with `pointerEvents="none"` when hidden. Tests: `active-threads-footer-cta.test.ts` (5 tests).

- [x] **[M-09] Auto-scroll briga com scroll manual durante streaming** — `chat-screen.tsx:464`
  - Cada update de streaming rola para bottom. Impossivel ler mensagens anteriores durante resposta ativa.
  - **Fix**: Detectar scroll manual e pausar auto-scroll. Mostrar FAB "Scroll to bottom" para retornar.
  - **Done**: Added userScrolledUpRef with 48px threshold. Auto-scroll paused when user scrolls up. Tests: `auto-scroll.test.ts` (17 tests pass)

- [x] **[M-10] Tool auto-expand sem animacao causa layout jump** — `streamingTimeline.tsx:245`
  - Apos 2s, tool item expande instantaneamente. Conteudo abaixo pula.
  - **Fix**: Usar `LayoutAnimation` do React Native para animar a expansao. Ou `Animated` com height interpolation.
  - **Done**: Added `LayoutAnimation.configureNext(easeInEaseOut)` before both auto-expand and manual toggle. Tests: `streamingTimeline.test.ts` (20 tests, 69 assertions).

- [x] **[M-11] Thread list inteira substituida por spinner durante refetch** — `thread-selection-screen.tsx:160`
  - `shouldShowThreadsLoading` em refetch mostra spinner no lugar da lista. Lista desaparece e reaparece.
  - **Fix**: Usar `isFetching` vs `isLoading` (TanStack Query distinction). Mostrar spinner overlay sem remover a lista. Ou confiar no cache.
  - **Done**: Added `isBackgroundRefetching` flag distinguishing initial load from background refetch. During refetch, list stays visible at opacity 0.7 with subtle spinner. Tests: `thread-loading-behavior.test.ts` (10 tests, 28 assertions).

- [x] **[M-12] Splash screen esconde antes do conteudo estar pronto** — `root-layout-content.tsx:88`
  - `SplashScreen.hideAsync()` e chamado no mount sem esperar dados. Animacao splash (~244ms) pode terminar antes da primeira tela renderizar.
  - **Fix**: So chamar `SplashScreen.hideAsync()` quando `isConfigLoaded && isSessionLoaded`. Estender animacao se necessario.
  - **Done**: Gated `SplashScreen.hideAsync()` on `isConfigLoaded && isSessionLoaded`. Tests: `splash-screen-readiness.test.ts` (6 tests).

- [ ] **[M-13] Mensagens perdidas entre erro WS e reconexao** — `ws-client.ts:500`
  - `onerror` nao fecha o socket. Mensagens enviadas entre o erro e a reconexao falham silenciosamente.
  - **Fix**: Fechar socket explicitamente em `onerror`. Enfileirar mensagens durante reconexao.

- [x] **[M-14] `onFinish` instavel reinicia animacao do splash** — `animated-launch-splash.tsx:80`
  - `onFinish` em deps do `useEffect`. Parent re-render cria nova referencia -> effect re-executa -> animacao reinicia.
  - **Fix**: Usar `useRef` para `onFinish` callback. Ou memoizar com `useCallback` no parent.
  - **Done**: Added `onFinishRef` pattern. `onFinish` removed from effect deps. Tests: `animated-launch-splash.test.tsx` (3 tests pass)

- [ ] **[M-15] Apenas 5 mensagens visiveis por vez** — `use-messages-query.ts:8`
  - `MESSAGE_PAGE_SIZE = 5`. Mensagens antigas somem. Scroll para cima necessario para ver historico.
  - **Fix**: Aumentar para 20-30. Implementar FlatList com virtualizacao para performance.

### P2 — Medium

- [ ] **[M-16] Selection sync causa 6 setState em sequencia** — `use-workspace-shell.ts:652`
  - Sincronizacao do server seta projectId, chatId, permissionMode, model, reasoning, provider em cascata.
  - **Fix**: Consolidar em um unico dispatch/batch update.

- [ ] **[M-17] Active threads poll a cada 2.5s causa micro-stutters** — `use-workspace-shell.ts:574`
  - `refetchInterval: 2500` com `staleTime: 1000`. Re-renders periodicos em todos os consumers.
  - **Fix**: Aumentar intervalo para 5-10s. Ou usar WebSocket para push updates ao inves de polling.

- [ ] **[M-18] Redirect 180ms delayed ao chat sem selectedChatId** — `chat-screen.tsx:686`
  - Chat screen mostra loading/vazio por 180ms antes de redirecionar para threads.
  - **Fix**: Checar condicao de redirect antes de renderizar. Ou mostrar splash/overlay durante redirect.

- [ ] **[M-19] `isResolvingThreadSelection` mostra spinner de duracao variavel** — `chat-screen.tsx:403`
  - Ao abrir thread, "Opening thread..." aparece por tempo imprevisivel (0-500ms+).
  - **Fix**: Se < 200ms, nao mostrar nada. Se > 200ms, mostrar skeleton. Evitar spinner para operacoes sub-segundo.

- [ ] **[M-20] Flash de streaming text -> timeline items na transicao** — `chat-screen.tsx:1445`
  - Quando streaming muda de delta-only para structured events, conteudo pode duplicar ou sumir por 1 frame.
  - **Fix**: Manter streaming text como fallback ate o primeiro item do timeline renderizar.

- [ ] **[M-21] Drawer pode ficar stuck em estado half-open** — `chat-screen.tsx:781`
  - Taps rapidos durante animacao: `isDrawerOpen` true enquanto close animation roda. Nao ha lock.
  - **Fix**: Adicionar `isAnimatingRef` para prevenir interacoes durante transicao.

- [x] **[M-22] Layout shift na workspace selection (spinner -> lista)** — `workspace-selection-screen.tsx:268`
  - ActivityIndicator centralizado pula para lista completa sem transicao.
  - **Fix**: Skeleton cards. Ou posicionar spinner no topo da lista sem mudar layout.

- [ ] **[M-23] LAN scan reseta lista antes de ter novos resultados** — `settings-screen.tsx:206`
  - `setDiscoveredServers([])` no inicio do scan. Lista some, depois repopula.
  - **Fix**: Manter resultados anteriores durante scan. Substituir atomicamente quando novos resultados chegarem.

- [x] **[M-24] Double reconnect em onerror + onclose** — `ws-client.ts:488`
  - Ambos chamam `scheduleReconnect()`. Pode incrementar `reconnectAttempts` 2x, dobrando o backoff.
  - **Fix**: Usar flag para deduplicate. `onerror` deve marcar estado mas so `onclose` agenda reconexao.
  - **Done**: `onerror` now calls `closeSocket()` instead of `scheduleReconnect()`. Only `onclose` reconnects. Tests: `ws-client-reconnect.test.ts` (5 tests).

- [ ] **[M-25] Render cache invalida quando callbacks mudam de identity** — `streamingTimeline.tsx:295`
  - Comparacao de referencia de callbacks. Se parent re-renderiza sem memoizar, toda a lista re-renderiza.
  - **Fix**: Memoizar todos os callbacks passados para StreamingTimeline. Ou remover callback comparison do cache check.

- [x] **[M-26] `initialData: createEmptyPage()` causa flash de empty state** — `use-messages-query.ts:118`
  - Ao abrir chat com mensagens, "Start a conversation." aparece por 1 frame antes das mensagens carregarem.
  - **Fix**: Nao usar `initialData`. Ou inicializar com `undefined` e mostrar skeleton quando `isLoading`.

- [ ] **[M-27] Deep link sem loading indicator** — `root-layout-content.tsx:114`
  - Auth callback via deep link processa async sem feedback visual. Tela default aparece brevemente.
  - **Fix**: Mostrar overlay/spinner durante processamento de deep link.

- [ ] **[M-28] Splash animation muito rapida (~244ms)** — `animated-launch-splash.tsx:19`
  - Animacao termina antes do conteudo carregar, revelando tela vazia.
  - **Fix**: Vincular termino da animacao ao readiness do conteudo. Estender fade-out se necessario.

### P3 — Low

- [ ] **[M-29] Toast sobrepoe FAB button** — `thread-selection-screen.tsx:415`
  - Toast e FAB no mesmo bottom position. Toast fica por cima.
  - **Fix**: Subir posicao do toast quando FAB esta visivel.

- [x] **[M-30] Flash de "No workspace selected" antes de redirect** — `thread-selection-screen.tsx:116`
  - Breve flash do subtitle incorreto antes de navegar para /workspaces.

- [ ] **[M-31] Loading/empty race no active-threads** — `active-threads-screen.tsx:68`
  - Com cache vazio, `isLoading=false` + `visibleThreads=[]` mostra empty state antes do fetch.

- [ ] **[M-32] pendingRouteRef pode bloquear navegacao permanentemente** — `use-flow-navigator.ts:19`
  - Se navegacao falha, ref nunca limpa, bloqueando futuros taps no mesmo destino.
  - **Fix**: Adicionar timeout de 3s para limpar pendingRouteRef.

- [ ] **[M-33] Queue overflow silenciosamente descarta mensagens** — `ws-client.ts:374`
  - Fila > 50 items: `shift()` remove a mais antiga (pode ser `join_chat` critico).
  - **Fix**: Priorizar mensagens de subscription sobre mensagens de user. Ou aumentar limite.

- [ ] **[M-34] Health check redirect causa flash de workspace screen** — `workspace-selection-screen.tsx:76`
  - Tela renderiza parcialmente antes de detectar erro e redirecionar para settings.

- [ ] **[M-35] Config providers sequenciais adicionam latencia ao boot** — `api-config-provider.tsx:26` + `private-session-provider.tsx:81`
  - Dois `isLoaded` flags que precisam completar antes do app funcionar.
  - **Fix**: Paralelizar carregamento. Ou unificar em um unico provider.

---

## CROSS-PLATFORM (Desktop + Mobile)

### Consistencia entre plataformas

- [ ] **[X-01] Streaming timeline: comportamento de auto-expand/collapse deve ser identico**
  - Desktop e mobile tem a mesma logica mas implementacoes separadas. Garantir paridade.

- [ ] **[X-02] Message window size**: Desktop usa 5, Mobile usa 5. Ambos muito baixos.
  - Aumentar para 20-30 em ambas as plataformas.

- [ ] **[X-03] Auto-scroll behavior** deve ser consistente.
  - Ambas as plataformas brigam com scroll do usuario durante streaming. Resolver igualmente.

- [ ] **[X-04] Loading states** devem usar skeleton screens em vez de spinners/texto.
  - Nem desktop nem mobile usam skeletons. Implementar padrao compartilhado.

- [ ] **[X-05] State management**: Ambas as plataformas sofrem de render cascades por multiplos useState.
  - Migrar para useReducer ou estado consolidado em ambas.

---

## Resumo

| Prioridade | Desktop | Mobile | Cross-Platform | Total |
|------------|---------|--------|----------------|-------|
| P0 Critical | 1 | 2 | -- | **3** |
| P1 High | 12 | 13 | -- | **25** |
| P2 Medium | 11 | 13 | 5 | **29** |
| P3 Low | 10 | 7 | -- | **17** |
| **Total** | **34** | **35** | **5** | **74** |

---

## Ordem de Ataque Recomendada

### Sprint 1 — Criticos + Quick Wins
1. `[M-01]` Fix WebSocket reconnect loop (critical, causa perda de dados)
2. `[M-02]` Manter streaming text visivel ate mensagem final (critical, conteudo some)
3. `[D-01]` Bootstrap batch (critical, pessima primeira impressao)
4. `[D-07]` + `[M-26]` Loading states iniciais corretos (quick win, elimina flash de empty)
5. `[M-14]` Fix splash animation onFinish instability (quick win)

### Sprint 2 — Render Performance
6. `[M-03]` + `[D-16]` Consolidar state management (useReducer)
7. `[M-07]` Extrair sub-componentes memoizados do chat-screen
8. `[D-23]` Pointer listener via ref no Three.js

### Sprint 3 — Scroll & Layout
9. `[D-11]` + `[M-09]` Auto-scroll respeitando posicao do usuario
10. `[D-09]` + `[M-10]` Tool auto-expand com animacao
11. `[D-12]` Terminal panel com animacao de resize
12. `[M-08]` Active threads banner sem layout shift

### Sprint 4 — State Transitions
13. `[D-02]` Preservar streaming state entre chats
14. `[D-04]` + `[D-05]` SET_CHATS/UPSERT_CHAT nao forcar selecao
15. `[M-04]` + `[M-05]` Chat switch e foreground atomicos
16. `[M-11]` Thread list: spinner overlay ao inves de replacement

### Sprint 5 — Polish
17. `[D-13]` Fontes locais / preload
18. `[D-03]` Remover fade-in do layout
19. `[M-12]` Splash screen timing correto
20. `[X-04]` Skeleton screens em todas as listas
21. Restante dos P3
