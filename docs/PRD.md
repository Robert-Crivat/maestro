# Maestro — PRD (v0.2, prototipo locale)

Window manager per macOS che unisce la griglia di Divvy e le azioni da tastiera di Rectangle.
Scelte della v0.2: `docs/decisioni/0001-impostazioni-v0.2.md`. Le note di ricerca su Divvy e Rectangle restano private, fuori dalla repo.

## Cosa fa

- App nella barra dei menu, Swift + AppKit/SwiftUI, nessuna dipendenza esterna.
- **Griglia stile Divvy** (`⌃⌥G`): pannello con icona e titolo della finestra; trascini sulle celle e vedi l'anteprima sullo schermo.
  - `+` / `−` cambiano le colonne; `Esc` o un click fuori chiudono il pannello.
  - Tenendo ⌘ al rilascio, la selezione diventa un layout salvato.
- **Azioni stile Rectangle**: metà (premendo di nuovo, ciclo ½ → ⅔ → ⅓ oppure passaggio allo schermo accanto), terzi, quarti, massimizza, centra, ripristina, schermo successivo e precedente.
- **Layout salvati**: area della griglia + nome + scorciatoia + schermo (della finestra o del cursore).
- **Trascina ai bordi**: bordi, angoli e terzi in basso, con anteprima. La finestra riprende la dimensione di prima quando la stacchi.
- **Impostazioni** (`⌘,` dal menu), in cinque sezioni:
  - Generale: avvio al login, icona nella barra, spazio tra finestre, margini, schermo, ripetizione, cursore;
  - Scorciatoie: tutte modificabili;
  - Griglia e layout;
  - Trascina ai bordi;
  - App escluse.
- Menu della barra con sottomenu Terzi, Angoli e Layout salvati, più «Ignora «App»» per escludere al volo l'app attiva.

## Cosa NON fa (ancora)

- Azioni ⅔ e ¾ dedicate, scorciatoie per i singoli schermi, import/export della configurazione.
- Firma Developer ID, notarizzazione, aggiornamenti automatici, icona dell'app.

## Da chiarire

- Distribuzione: decisa. Repo pubblica su GitHub (`Robert-Crivat/maestro`), licenza MIT, DMG nelle release, non notarizzato.
- Username Buy Me a Coffee: segnaposto `YOUR_BMC_USERNAME` in README e `.github/FUNDING.yml`. [da chiarire]
- Scorciatoie predefinite definitive: oggi sono quelle di Rectangle, quindi le due app si pestano i piedi se sono aperte insieme. [da chiarire]

## Come si verifica

- `scripts/build-app.sh`: compila, esegue il selftest della geometria e crea `build/Maestro.app`. Dopo ogni build l'Accessibilità va riconcessa.
- Test end-to-end: `open -n build/Maestro.app --args --e2e=/percorso/report.txt`. Serve l'Accessibilità.
  - Apre una finestra di prova in un secondo processo e la guida con tastiera e mouse veri, circa 1 minuto.
  - Scrive il report, rimette le impostazioni com'erano ed esce.

## Stato

- 2026-10-17, giro completo: 70 controlli end-to-end su 71 verdi.
  - Coperti: azioni, ciclo ½ → ⅔ → ⅓, ripristino, 3 schermi, gap, margini, app escluse, cursore, scorciatoie modificate e rimosse, scorciatoia di layout, griglia (apertura, + e −, trascinamento, Esc, clic fuori, ⌘ al rilascio, messaggio), trascina ai bordi (sinistra, stacca, alto, terzi, angolo, spento), icona, avvio al login, menu, Impostazioni.
  - L'unico rosso (⌃⌥↓) era un difetto del test, non dell'app: con eventi freccia completi ⌃⌥↓ e ⌃⌥← funzionano. Il test è corretto nel sorgente; la `build/` attuale è quella testata.
- Non coperti dal test automatico: il clic sul campo scorciatoia in Impostazioni (la logica è coperta, l'interazione col campo no) e il pulsante «Salva» del foglio «Nuovo layout».
