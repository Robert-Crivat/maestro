# 0001 · Impostazioni e gestione (v0.2)

Data: 2026-10-17 · Mockup approvato: `docs/mockup/impostazioni.html`

## Contesto

La v0.1 aveva scorciatoie fisse, nessuna finestra impostazioni e una griglia spartana. L'utente ha chiesto impostazioni, gestione e una grafica più curata. Ha scelto queste funzioni: scorciatoie modificabili, layout griglia salvati, avvio al login + app escluse, trascina ai bordi.

## Decisioni

- **Finestra Impostazioni in SwiftUI** (`NavigationSplitView` + `Form` raggruppato): stile Impostazioni di Sistema senza disegnarlo a mano. Il pannello griglia resta AppKit (`NSPanel` non attivante), perché non deve rubare il focus all'app da spostare.
- **Persistenza in `UserDefaults`**: valori semplici come chiavi, scorciatoie e layout come JSON. Un solo modello osservabile (`Store`).
- **Scorciatoie globali sempre via Carbon `RegisterEventHotKey`**: nessun permesso extra. Mentre registri una combinazione le scorciatoie globali vengono sospese, altrimenti scatterebbero loro. Una combinazione rifiutata dal sistema viene segnata come «già usata da un'altra app».
- **Salvare un layout dalla griglia**: ⌘ tenuto premuto al rilascio, invece di ⌘S. Al rilascio la griglia si chiude e la selezione sparisce, quindi ⌘S non avrebbe più niente da salvare. Il risultato è lo stesso del mockup: si apre il foglio «Nuovo layout» già compilato.
- **Trascina ai bordi**: monitor globale del mouse; la finestra conta come "trascinata" quando si sposta senza cambiare dimensione. Stesso metodo di Rectangle.
- **Avvio al login** con `SMAppService.mainApp` (macOS 13+).

## Verificato durante l'implementazione

- `RegisterEventHotKey` **non segnala** le combinazioni già prese da altre app: con Rectangle aperto, ⌃⌥← si registra senza errori. Fallisce solo con un doppione dentro Maestro stesso. Per questo le Impostazioni e il menu avvisano quando sono aperti Rectangle, Divvy o Magnet, invece di promettere un rilevamento che non esiste.
- `navigationTitle` non arriva a una `NSWindow` creata a mano con `NSHostingController`: la finestra restava «Untitled». Il titolo viene impostato da `Store.pane`.
- **Firma con certificato self-signed: macOS rifiuta l'Accessibilità.** Con una firma ad-hoc il permesso si perde a ogni build. Ho provato un certificato locale per tenerlo stabile: la firma è valida, ma in Impostazioni di Sistema l'interruttore di Maestro torna spento da solo. Si resta sull'ad-hoc: a ogni build il permesso va riconcesso. Lo script azzera la voce vecchia, perché altrimenti l'interruttore resterebbe acceso senza funzionare.

- **Eventi tastiera simulati sulle frecce**: una scorciatoia Carbon su una freccia (⌃⌥↓) scatta solo se l'evento porta anche i flag tastierino numerico e Fn, come quelli di una tastiera vera. Senza, l'evento viene ignorato in silenzio: nel test sembrava un bug dell'app.
- **Bug corretto**: due campi scorciatoia potevano registrare insieme e prendersi entrambi la stessa combinazione. Ora c'è un solo registratore per tutta l'app (`Recorder`).

## Conseguenze

- Ogni nuova azione va aggiunta in tre punti: `Layout.Action`, `ActionGroup` e, se serve, `Store.defaultShortcuts`.
- Il trascina-ai-bordi di Maestro e quello nativo di macOS (dalla 15) si sovrappongono: la sezione lo dice e indica dove spegnere quello di sistema.
