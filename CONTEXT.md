# ci-workflows

Workflow e action riusabili con cui i progetti Laravel dell'organizzazione vengono verificati in CI e rilasciati sui server cPanel, a Release numerate.

## Linguaggio

### Release

**Release**:
Una copia completa e immutabile dell'applicazione, costruita da un deploy e depositata sul server in una directory con nome proprio (data, ora e commit).
_Avoid_: versione, build, rilascio

**current**:
Il collegamento che indica quale Release il sito sta servendo; attivare una Release significa spostarlo.
_Avoid_: release attiva, symlink

**shared**:
Ciò che sopravvive alle Release, come `.env` e `storage`, e che ogni Release collega invece di contenere.
_Avoid_: persistente, comune

### Smoke test della Release

**Smoke test della Release**:
La verifica che la Release appena attivata sia davvero quella in linea e che il sito sia sano.
_Avoid_: health check, sonda, probe

**Marcatore**:
Il file PHP temporaneo che, servito dal sito, dice quale Release PHP sta eseguendo; esiste solo per la durata dello smoke test.
_Avoid_: probe, sentinella, file di release

**smoke-from**:
Il punto da cui si misura il sito: `runner` (da GitHub, attraverso CDN e protezioni) o `server` (dalla connessione SSH del deploy).
_Avoid_: modalità di misura, origine

**Verdetto**:
La classificazione di una singola risposta al marcatore (`match`, `mismatch`, `no-response`, `challenged`, `html-page`, `redirect`).
_Avoid_: stato, risultato

**Esito**:
La conclusione dell'intero smoke test (`online`, `timeout`, `challenged`, `html-page`, `redirect`, `unhealthy`, `unavailable`, `usage`).
_Avoid_: verdetto, outcome

**decisions-script**:
Uno script del progetto chiamante che decide i verdetti al posto del default, per tenerli sotto test nella sua suite.
_Avoid_: hook, callback, regole custom
