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
- Sparkle punta all'appcast upstream (`SUFeedURL` in Info.plist): non accettare gli aggiornamenti proposti dall'app, sovrascriverebbero il fork con la release ufficiale.
