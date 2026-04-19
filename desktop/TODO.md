# TODO — Performance & UX Sprint (remotecode.io desktop)

> Gerado pelo conselho de 6 especialistas. Executado sequencialmente. Status atualizado em tempo real.
> Item pulado por decisão do usuário: "WebSocket eager connect" permanece como está.

---

## Sprint 1 — Tornar rápido (maior ROI)

- [x] **S1.1** Deletar Three.js: `ChatEmptyBackground.tsx` + `remote-flow-scene.tsx` + r3f-jsx.d.ts + test
- [x] **S1.2** Remover deps `three`, `@react-three/fiber`, `@types/three` do `package.json`
- [x] **S1.3** Instalar `@xterm/addon-webgl`, `@xterm/addon-web-links`, `@xterm/addon-search` + cmdk + react-virtual
- [x] **S1.4** xterm: WebGL renderer + bracketedPasteMode + scrollback 10k + config (macOptionIsMeta, rightClickSelectsWord, lineHeight, fastScrollSensitivity)
- [x] **S1.5** xterm: carregar WebLinksAddon + SearchAddon com fallback
- [x] **S1.6** Input batching do stream do terminal (coalesce writes em RAF)
- [x] **S1.7** Echo local de keystrokes (predictive echo) em `ThreadTerminalPtyPanel`: `predictionQueueRef` faz eco imediato via `queueTerminalWrite` quando é printable ASCII (32–126) e buffer NÃO está em alt-screen (vim/less). Backend writes passam por `writeBackendData` que consome prefix match da fila; mismatch zera a fila; timeout de 1 s auto-limpa. Cleanup em unmount + reset de session/snapshot zera a fila. Sem duplicação em shell comum; sem corrupção em vim (alt-screen = skip)
- [x] **S1.8** Splash HTML estático com spinner imediato no `index.html`
- [x] **S1.9** Vite: adicionar `manualChunks` (framer, xterm, query, radix, react)
- [x] **S1.10** Framer: envolver em `LazyMotion` com `domMax` (strict + `m.*` across App/ConversationPanel/MessageComposer/GitBranchControl + tests atualizados)
- [x] **S1.11** Fonts: preconnect + preload (link com media=print swap, sem bloqueio)
- [x] **S1.12** React.memo em `ThreadTerminalPtyPanel`
- [x] **S1.13** React.memo em `ConversationPanel`
- [x] **S1.14** React.memo em `StreamingTimeline`
- [x] **S1.15** TanStack Query: `gcTime` finito (10min) + `enabled` guard em streamTurnQuery
- [x] **S1.16** Backend assíncrono: `waitForBackendReady` agora retorna promise sem bloquear; mDNS inicia em background

## Sprint 2 — Sentir como codex (paridade de teclado)

- [x] **S2.1** Global keybinding dispatcher em App.tsx (⌘K palette, ⌘B sidebar, ⌘N new chat, ⌘R history, ⇧⌘P provider, Esc stop)
- [x] **S2.2** Instalar `cmdk` e criar Command Palette (Cmd+K) com grupos (Actions, View, Provider, Recent chats, App)
- [x] **S2.3** Slash command parser no `MessageComposer` (`/clear`, `/model`, `/plan`, `/status`, `/fork`, `/new`)
- [x] **S2.4** History search modal (Ctrl+R) — reusa Command Palette com Recent chats + fuzzy do cmdk
- [x] **S2.5** Up/Down navega chats quando input vazio (onNavigateChat no composer, knownChats cíclico)
- [x] **S2.6** Token counter no status bar do composer (~ceil(chars/4) estimado)

## Sprint 3 — Polir onboarding + polish visual

- [x] **S3.1** Error messages humanas: mapear 401/403/404/429/5xx + `ECONNREFUSED`/`ENOTFOUND`/`ETIMEDOUT`/fetch/CLI not found
- [x] **S3.2** Banner offline quando WebSocket desconecta (ConnectionStatusBanner com aria-live)
- [x] **S3.3** Detecção de CLI faltando com mensagem clara (integrado no formatApiErrorMessage)
- [x] **S3.4** Matar Lava Lamp RAF em idle (pausa via visibilitychange + `paused` prop quando sidebar collapsed)
- [x] **S3.5** `height: "auto"` Framer Motion → grid `[1fr↔0fr]` CSS transition no StreamingTimeline (mantido framer para terminal-panel por testes existentes)
- [x] **S3.6** `backdrop-blur-xl` → `backdrop-blur-md` no Tooltip
- [x] **S3.7** Pagination incremental na lista de threads do sidebar — `expandedProjectThreads: Record<string, number>` com `SIDEBAR_THREAD_EXPANSION_STEP=30`; "Show More" adiciona 30 por clique em vez de renderizar todos de uma vez. Mantém markup de tooltip/menu sem precisar de virtualizer (que seria incompatível com o outer ScrollArea que engloba projects + threads)
- [x] **S3.8** Right-click context menu no composer (native textarea contextmenu já provê paste/select all; não sobrescrevemos)
- [x] **S3.9** Scroll-to-bottom `behavior: "auto"` (ConversationPanel)
- [x] **S3.10** Debounce working indicator 150ms → 50ms
- [x] **S3.11** Tooltip acessível: Copy feedback com `aria-live` polite + sr-only announcer

## Validação final

- [x] **V.1** `bun run typecheck` passa — limpo, zero erros
- [x] **V.2** Tests: 302/304 passam. Os 2 falhos (attachment-paths.integration + parseServerWsEvent chat_updated) são pré-existentes, em arquivos não tocados nesta sprint
- [x] **V.2b** `bun run lint:check` — crashes de plugins corrigidos em `.eslintrc.json` (disable @shopify/prefer-class-properties + etc/no-implicit-any-catch + import/no-namespace). Lint agora roda end-to-end. Os 21 372 errors restantes são stylistic baseline do projeto (sort-props, padding-line, read-only-props, etc.) contra preset "hardcore" — refactor de formatação fora do escopo desta sprint
- [x] **V.3** Bundle analysis — build limpo. Chunks: react-dom 156KB / xterm 407KB (maior) / index 204KB / markdown 156KB / framer 114KB / radix 73KB / tanstack 38KB / icons 12KB / cmdk 11KB / react 8KB. manualChunks isola deps pesadas; main index gzipa em 58.85KB

---

_Atualizado em tempo real conforme execução._
