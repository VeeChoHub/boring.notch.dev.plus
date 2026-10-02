# Boring Notch (fork)

## Aggiornare l'app installata dopo ogni modifica

Dopo ogni cambiamento al codice, dalla root della repo:

```sh
./install.sh
```

Lo script compila in Release, firma con il certificato locale, chiude l'app in esecuzione e la sostituisce in `/Applications`, poi la riavvia.
Verifica che giri: `pgrep -fl "Boring Notch"`. Se non parte, lancia il binario a mano per vedere l'errore:
`"/Applications/Boring Notch.app/Contents/MacOS/Boring Notch"`.

Note (le motivazioni sono anche commentate in `install.sh`):
- Firma: al primo avvio lo script crea il certificato self-signed "Boring Notch Local" nel portachiavi login. È normale che `security find-identity` lo mostri come `CSSMERR_TP_NOT_TRUSTED`: per firmare basta così. Grazie al certificato i permessi macOS (Accessibilità, Calendario, Fotocamera) restano validi tra una build e l'altra. Firma app principale + `BoringNotchXPCHelper.xpc` (è lui a chiedere l'Accessibilità).
- `ENABLE_HARDENED_RUNTIME=NO` è obbligatorio: con hardened runtime la library validation blocca `MediaRemoteAdapter.framework` (crash all'avvio con "different Team IDs"). Non modificare il progetto per questo, solo il flag da riga di comando.
- Chiusura con `osascript ... quit`, non `pkill`: l'app ignora SIGTERM. Il processo `perl` `mediaremote-adapter.pl` sopravvive alla chiusura dell'app, lo script lo termina.
- Impostazioni: stanno nel container sandbox `~/Library/Containers/theboringteam.boringnotch/` e sopravvivono alla reinstallazione. Con la firma a certificato macOS protegge il container: dal terminale `ls`/`plutil` danno "Operation not permitted", è normale.
- `build/` è già in `.gitignore`.
- Avvio al login: configurato come login item di macOS sul path `/Applications/Boring Notch.app`, sopravvive alle reinstallazioni. Il toggle "Launch at login" nelle impostazioni dell'app (SMAppService) è ridondante: lascialo spento.
- Sparkle ("Controlla aggiornamenti") legge l'`appcast.xml` allegato all'ultima release del fork (`SUFeedURL` = `releases/latest/download/appcast.xml`). La verifica usa la nostra chiave EdDSA (`SUPublicEDKey`), la cui privata è nel Portachiavi di login. Senza la privata non si possono firmare aggiornamenti: tienine un backup (`generate_keys -x`). Sparkle confronta il numero di build (`CURRENT_PROJECT_VERSION`), non la versione.

## Push = release

Ogni push si fa con `./release.sh`, mai con `git push` da solo. Va lanciato con il working tree pulito (prima committa).
Senza argomenti usa la versione successiva all'ultimo tag (`2.7.3-plus.N` → `N+1`); in alternativa `./release.sh <versione>`.
Lo script, in ordine:
1. alza build e versione nel pbxproj;
2. compila universale e installa in locale (`UNIVERSAL=1 ./install.sh`);
3. crea `build/release/archives/boringNotch.dmg` e l'appcast firmato (`generate_appcast`, legge la chiave dal Portachiavi);
4. committa il bump, crea il tag `v<versione>`, fa push di branch e tag;
5. pubblica la release su GitHub con dmg e `appcast.xml`, segnata come latest.

Le app installate la ricevono da "Controlla aggiornamenti".

## Live activity Claude Code

`claude-hook.js` è registrato come hook (e nella statusline) in `~/.claude/settings.json` dal bottone Install nelle impostazioni (sezione Claude Code, sparisce quando è registrato): `BoringNotchXPCHelper.claudeHook` lancia `claude-hook.js install` (backup in `settings.json.bak`). Lo script usato è la copia che `install.sh` mette in `Contents/Resources` dell'app, quindi le modifiche a `claude-hook.js` valgono dopo `./install.sh`. Eventi: (SessionStart, UserPromptSubmit, PreToolUse con matcher AskUserQuestion|ExitPlanMode, PermissionRequest, PostToolUse, PostToolUseFailure, Stop, StopFailure, SessionEnd, Notification con matcher idle_prompt, SubagentStart, SubagentStop). Invia la distributed notification `boringnotch.claude.<stato>` (idle/working/done/question/permission, `ended` rimuove; `done` = hook Stop, "<nome> Completata" nel notch chiuso, che si allunga sotto la fotocamera (al posto di logo + spunta), per 5 s poi idle; sotto: modello · contesto | token e costo della task, calcolati dall'hook Stop sul transcript dal `prompt_id` corrente con le regole di `cost.py` di task-notifier, in userInfo `task`) con object = session_id e userInfo `{cwd}`; la riceve `BoringViewCoordinator.claudeSessions`.
- Esc durante una risposta non fa scattare nessun hook (né Stop né idle_prompt): lo rileva il ramo statusline di `claude-hook.js`, che legge l'ultima riga del transcript (`[Request interrupted by user…]`) e manda `idle` con `at`; l'app lo ignora se più vecchio dell'ultimo cambio di stato. Esc durante un tool arriva come `PostToolUseFailure` con `is_interrupt`.
- Subagent: `SubagentStart`/`SubagentStop` inviano `boringnotch.claude.agent` (userInfo `{agent, done}`); l'app conta per sessione l'ultimo gruppo lanciato (`ClaudeSession.agents`) e al posto di "Al lavoro" mostra "SubAgent x/y". Uno `Stop` con subagent/workflow ancora in `background_tasks` ("Waiting for N background agents") manda `working`, non `done`; mentre ci sono subagent attivi l'app ignora anche `idle` (idle_prompt scatta comunque dopo 60 s).
- Contesto: il ramo statusline inoltra `context_window.used_percentage` come `boringnotch.claude.context` (userInfo `{pct, model, tokens}`, es. `Opus 5.5` e `85k/1M`; solo per sessioni già note all'app); la riga della sessione lo mostra dopo il titolo. Oltre 33% giallo con "!", oltre 66% rosso con "!!"; a 1 h da "Completata" (TTL della cache) diventa rosso con un "!" in più.
- Notch chiuso: logo + stato solo se almeno una sessione non è idle (priorità su tutto).
- Notch aperto: tab "Claude" (`ClaudeSessionsView`, al posto del tab Shelf) con tutte le sessioni aperte; se una lavora, l'hover apre direttamente lì (`BoringViewModel.open()`).
- Limiti di utilizzo (sezione in cima alla pagina Claude): anche `statusLine.command` in `~/.claude/settings.json` passa il suo input a `claude-hook.js`, che inoltra `rate_limits` (solo `five_hour` e `seven_day`, gli unici esposti) come `boringnotch.claude.limits`; l'app lo salva in `@AppStorage("claudeLimits")`.
- Chat nel notch (bottone in fondo alla pagina Claude, `ClaudeChatView.swift`): l'app è in sandbox, quindi `claude` lo lancia `BoringNotchXPCHelper.runClaude` (fuori sandbox), un `claude -p --resume <id>` per messaggio nella home, con i permessi di `~/.claude/settings.json`. L'helper ha `JoinExistingSession = true` nel suo `Info.plist`: senza, launchd avvia il servizio XPC in una sessione di sicurezza nuova dove il Portachiavi di login è bloccato, `security` esce con 36 e claude risulta "Not logged in". Testo e tool arrivano come `boringnotch.claude.chat`; messaggi e session_id sono in UserDefaults finché l'utente non scrive `/clear`. Il protocollo XPC esiste in due copie (app e helper): tenerle allineate.
- Debug nell'app: Impostazioni → Advanced → "Claude Extension Debug Mode" (`ClaudeDebugSection` in `SettingsView.swift`): simula la card "Completata" con valori a scelta, una sessione finta (stato, subagent x/y, contesto %, cache scaduta), mostra il log degli ultimi cambi di stato (`BoringViewCoordinator.claudeLog`) e rimuove tutte le sessioni. Le simulazioni passano da `updateClaudeSession`, lo stesso metodo usato dagli hook (niente distributed notification dall'app: in sandbox perderebbe lo userInfo).
- Prova senza Claude: `echo '{"hook_event_name":"UserPromptSubmit","session_id":"t","cwd":"/tmp/x"}' | ./claude-hook.js` (poi `SessionEnd` per toglierla).
