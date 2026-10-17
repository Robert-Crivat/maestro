# 0002 · Distribuzione pubblica (v0.2.0)

Data: 2026-10-17

## Decisioni

- Repo pubblica `Robert-Crivat/maestro`, licenza MIT, README in inglese (l'app per ora resta in italiano).
- Si distribuisce come **DMG nelle GitHub Release**: app + collegamento ad Applicazioni + icona del volume, con un file `.sha256` accanto.
- **App universale** (Apple Silicon + Intel), firma ad-hoc, **non notarizzata**. Senza account Apple Developer, alla prima apertura serve «Apri comunque» oppure `xattr -dr com.apple.quarantine`, e il README lo spiega.
- Le note di reverse engineering su Divvy restano fuori dalla repo (`.gitignore`): contengono dettagli ricavati dal disassemblato di un'app commerciale.
- Buy Me a Coffee: segnaposto `YOUR_BMC_USERNAME` in README e `.github/FUNDING.yml`, finché l'utente non crea l'account.

## Verificato

- `swift build --arch arm64 --arch x86_64` richiede Xcode completo (xcbuild). Con i soli Command Line Tools si compila una slice per `--triple` e si uniscono con `lipo` (`scripts/build-app.sh`).
- Il file `.sha256` deve contenere solo il nome del DMG, non `build/…`, altrimenti `shasum -c` fallisce a chi scarica. Corretto in `scripts/make-dmg.sh` e ricaricato nella release.
- L'immagine di anteprima social della repo non si imposta via API: va caricata a mano (Settings → General → Social preview → `assets/banner.png`).
