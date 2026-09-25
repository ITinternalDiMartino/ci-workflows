# setup-releases.sh

Prepara un dominio cPanel per `laravel-projects-deploy.yml`: impianta il layout a
rotazione su un dominio nuovo, oppure ci migra un sito già in linea su un progetto
piatto, senza cancellare niente finché il sito non ha risposto dalla nuova
posizione.

```
<BASE>/
  current -> releases/<release>   document root: <BASE>/current/public
  releases/                       una directory per release
  shared/.env                     configurazione persistente
  shared/storage/                 storage persistente
  tmp/                            transito dell'archivio di deploy
```

## Come si esegue

Dal proprio computer, senza lasciare niente sul server:

```sh
ssh utente@host 'sh -s' -- <fase> <--new|--from-existing> <BASE> [opzioni] < scripts/setup-releases.sh
```

Non è una GitHub Action perché gira **prima** che l'Environment e i secret SSH
esistano. Siccome `sh -s` legge lo script da stdin, nessuna fase chiede niente:
ognuna è un comando a sé.

| opzione | default | a cosa serve |
|---|---|---|
| `--url URL` | `APP_URL` del `.env` | URL interrogato dalle sonde |
| `--php-bin PATH` | il PHP del dominio | `PHP_BIN` da verificare in `recon` |
| `--health-path P` | `/` | percorso che deve rispondere 2xx/3xx in `legacy` e `cleanup` |
| `--timeout N` | `150` | secondi di attesa della sonda di release |
| `--no-color` | | output senza sequenze ANSI |

## Le due modalità

| | `recon` | `bridge` | `shared` | `legacy` | `cleanup` |
|---|:-:|:-:|:-:|:-:|:-:|
| `--from-existing` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `--new` | ✓ | | ✓ | | |

Su un dominio nuovo non c'è niente da servire: il ponte non avrebbe oggetto, le
sonde risponderebbero 404 comunque e non c'è nessun sito piatto da archiviare. Una
fase che non fa niente, o una verifica che passa sempre, insegnerebbe solo a
ignorarla, quindi in `--new` quelle fasi non esistono.

## Migrazione di un sito in linea

```sh
S='ssh utente@host sh -s --'
B=/home/utente/dominio.it

$S recon   --from-existing $B < scripts/setup-releases.sh
$S bridge  --from-existing $B < scripts/setup-releases.sh
#  pannello cPanel: document root del dominio -> $B/current/public
$S shared  --from-existing $B < scripts/setup-releases.sh
$S legacy  --from-existing $B < scripts/setup-releases.sh
$S cleanup --from-existing $B < scripts/setup-releases.sh
#  pannello cPanel: cron su $B/current/artisan
$S recon   --from-existing $B < scripts/setup-releases.sh   # fino a "pronto: sì"
#  primo deploy, sullo stesso commit già in produzione
```

Il perno è che `current` può puntare a `$BASE` stesso: allora
`$BASE/current/public` **è** `$BASE/public`, cioè quello che il sito piatto serve
già. Il ponte esiste prima che esista una release. cPanel accetta un document root
che passa per un symlink (verificato nella migrazione a mano del 24 settembre
2026).

1. **`bridge`** crea `current → $BASE`. Nessun effetto visibile.
2. **Cambio del document root** dal pannello. Il sito serve gli stessi file
   attraverso `current`, e un clic riporta indietro: la mossa rischiosa è la prima,
   ed è isolata.
3. **`shared`**. Solo adesso `$BASE` non è più servito, quindi `shared/.env` non è
   mai raggiungibile dal web. `.env` e `storage/` si spostano e si ricollegano: il
   sito continua a leggere e scrivere gli stessi inode, niente doppia copia, niente
   `rsync` finale.
4. **`legacy`**, poi **`cleanup`**.
5. **Cron** su `$BASE/current/artisan`: lo script li elenca con il path corretto
   accanto, ma non li tocca.
6. **Primo deploy sullo stesso commit già in produzione**: nessuna migrazione
   pendente, nessuno schema che cambia fra lo swap e il codice vecchio.

## Dominio nuovo

```sh
$S recon  --new $B < scripts/setup-releases.sh
$S shared --new $B < scripts/setup-releases.sh
#  compilare a mano $B/shared/.env, con APP_KEY, chmod 600
$S recon  --new $B < scripts/setup-releases.sh   # fino a "pronto: sì"
```

Il document root si cambia quando si vuole: fino al primo deploy il dominio è rotto
comunque.

## Le fasi

**`recon`** legge e stampa, non tocca niente. È anche il dry-run e la verifica
finale: stampa tutto quello che ha letto, non un riassunto, e chiude con
`pronto per il primo deploy: sì` oppure con l'elenco di cosa manca. Fra sei mesi
dice com'è messo quel server a chiunque ci torni. Esce con 0 solo se il verdetto è
sì.

- la modalità, nella prima riga; subito dopo, cos'è `current` (vedi la trappola);
- le voci della cartella, con quelle che non riconosce segnalate, i symlink, dove
  stanno `.env` e `storage/`;
- `releases/`, `shared/`, `tmp/`, `shared/.env` (permessi, `APP_KEY` valorizzata o
  no, mai il valore) e l'albero di `shared/storage`;
- in `--from-existing`, a che punto è la migrazione: archivio, `releases/000-legacy`,
  file originali ancora nella home, fase successiva;
- i cron dell'utente che nominano `$BASE`, con accanto il path corretto;
- il PHP del dominio accanto a `PHP_BIN` (vedi sotto) e il document root, se
  `uapi` lo sa dire.

**`bridge`** crea `current → $BASE` e si ferma. Rifiuta di lavorare se `current`
esiste già e non punta a `$BASE`.

**`shared`** verifica con le sonde che il document root sia cambiato, crea
`releases/`, `shared/` e `tmp/`, sposta `.env` e `storage/` in `shared/` lasciando
un symlink di ritorno, e stampa le vars e le righe da mettere nel `deploy.yml`. Il
`.env` passa per un hard link seguito da una rename del symlink, quindi il sito
vecchio non lo vede mai mancare.

**`legacy`** porta il sito piatto dentro `releases/000-legacy`, senza cancellare
niente:

1. archivia in `shared/000-legacy.tar.gz` il contenuto di `$BASE` escluse
   `releases/`, `shared/`, `tmp/` e `current`, con `tar -h`: i symlink sono
   dereferenziati, quindi l'archivio contiene il `.env` e lo `storage/` veri ed è
   una fotografia completa dello stato pre-migrazione. `chmod 600`;
2. estrae l'archivio in `releases/000-legacy/` saltando `.env`, `storage/` e, se
   era un symlink, `public/storage`. I path assoluti di `bootstrap/cache/config.php`
   vengono riscritti verso la copia: puntavano a `$BASE/storage` e a
   `$BASE/resources`, che dopo `cleanup` non esistono più;
3. ricrea i collegamenti con target relativo (`ln -srfT`) verso `shared/`: i
   symlink dell'archivio non servono, perché `$BASE/.env → shared/.env` dentro la
   release punterebbe a `releases/000-legacy/shared/.env`;
4. sposta `current` su `releases/000-legacy` con lo stesso `ln -sfn` + `mv -Tf` del
   deploy;
5. interroga il sito. Se non risponde, **riporta `current` su `$BASE` da solo** e si
   ferma. Non ha cancellato niente, e la fase si rilancia: riparte dal passo 3.

Prima di cominciare controlla che il sito risponda già, e che ci sia spazio per
archivio e copia.

**`cleanup`** cancella dalla home i file originali. Gira solo se `current` risolve
in `releases/000-legacy` e la sonda è verde. Cancella solo le voci che sono
nell'archivio e che la copia contiene: quello che è comparso in `$BASE` dopo
l'archivio resta dov'è ed è elencato. `shared/000-legacy.tar.gz` non lo tocca.

## La trappola: `current` creata come directory

Impostando il document root a `/current/public` alla creazione del dominio,
**cPanel crea `current` come directory vera**. Va cancellata prima del primo
deploy.

Se resta, il deploy fallisce in modo fuorviante. `Activate release` fa
`ln -sfn "$REL" "$CUR.new"` e poi `mv -Tf "$CUR.new" "$CUR"`. `mv -T` si rifiuta di
sovrascrivere una directory, quindi scatta il ripiego `ln -sfn "$REL" "$CUR"`, che
con `$CUR` directory vera non la sostituisce ma ci crea **dentro** un symlink
`current/<nome-release>`. Il controllo finale vede `current` che risolve in sé
stessa, e il run muore con `lo swap non ha avuto effetto`: un messaggio che non
nomina la causa.

`recon` la segnala in rosso prima di ogni altro controllo, in entrambe le modalità.
Nessuna fase la cancella, perché lo script non cancella una directory che non ha
creato lui: la si guarda e la si toglie a mano.

## `rotation-exclude: 000-legacy` è obbligatoria

Nel `deploy.yml` del progetto migrato:

```yaml
    with:
      rotation-exclude: 000-legacy
```

`000-legacy` ordina prima di qualunque release `YYYYMMDD-HHMMSS-sha7`, quindi
`sort -r` la mette in coda ed è la **prima** che la rotazione cancella. Senza
quella riga la seconda rete di sicurezza sparisce al primo deploy riuscito, in
silenzio. `shared` la stampa accanto alle vars.

## Le reti di sicurezza, in ordine

| quando | come si torna indietro |
|---|---|
| prima di `cleanup` | `ln -sfn $BASE $BASE/current.new && mv -Tf $BASE/current.new $BASE/current`: il sito piatto è ancora nella home, intero |
| dopo `cleanup` | `ln -sfn $BASE/releases/000-legacy $BASE/current.new && mv -Tf $BASE/current.new $BASE/current`: la copia è una release come le altre |
| sempre | `shared/000-legacy.tar.gz` |

Il prezzo è tenere per un po' tre copie del codice (originali, archivio, release),
mentre `storage/`, la parte pesante, resta in una copia sola in `shared/`.
L'archivio lo toglie una persona, quando lo decide.

## Le sonde

Tutte partono dal server, come il deploy con `smoke-from: server`.

**Document root, in `shared`.** La fase deve *sapere* che `$BASE` non è più
servito, altrimenti sta per mettere il `.env` in una cartella raggiungibile dal
web. Scrive due sonde con token diversi e le chiede al dominio:

- `$BASE/__probe-root.txt`: se torna il suo token, `$BASE` è ancora servito e la
  fase si ferma. Con il document root su `current/public` nessuna riscrittura
  dell'`.htaccess` può raggiungerla;
- `$BASE/public/__probe-public.php`, che restituisce il token e
  `$_SERVER['DOCUMENT_ROOT']`. Deve finire in `/current/public` e risolvere in
  `$BASE/public`. È PHP e non un `.txt` perché, con `current → $BASE`, un document
  root `$BASE/public` (o `$BASE` con un `.htaccess` che riscrive su `public/`)
  serve esattamente gli stessi file di `$BASE/current/public`: solo il document
  root dichiarato li distingue.

Le sonde vengono cancellate subito dopo, e comunque all'uscita.

**Release, in `legacy` e `cleanup`.** Un file PHP che esiste solo dentro
`releases/000-legacy/public`. Dopo lo swap la realpath cache di PHP (120s di
default) può ancora risolvere `current` in `$BASE`, dove i file vecchi sono intatti:
senza aspettare quel token il sito risponderebbe verde anche con la copia rotta.
Tornato il token, `--health-path` deve rispondere 2xx o 3xx.

## PHP_BIN: mai `which php`

Su cPanel `which php` restituisce `/usr/local/bin/php`, il PHP di sistema, mentre
il dominio gira sulla versione scelta in MultiPHP. `recon` legge la versione del
dominio da `uapi LangPHP php_get_vhost_versions` (in mancanza, dall'handler che
MultiPHP scrive nell'`.htaccess`), elenca `/opt/cpanel/ea-php*/root/usr/bin/php` con
le loro versioni, e affianca le due perché siano guardate insieme. Se non
coincidono, il verdetto è no. Segnala anche i cron che chiamano il PHP di sistema.

## Cosa corregge e cosa si limita a stampare

Corregge quello che sa con certezza: l'albero di `shared/storage` (`app/public`,
`framework/{cache,sessions,views}`, `logs`), `chmod 600` sul `.env` e
sull'archivio, i permessi di scrittura su `storage`, i path di `config.php` nella
copia.

Stampa e basta: cron, vars, `rotation-exclude`, versioni PHP, `current` se è una
directory, e ogni voce della cartella che non riconosce.

Se `shared/` o `releases/000-legacy` esistono già, la fase si ferma invece di
rifare: rieseguibile vuol dire che la seconda esecuzione non fa danni, non che
ripara uno stato a metà. L'unica eccezione è `legacy` interrotta al passo 5, che
non ha cancellato niente e si rilancia. Una fase su uno stato già completo dice
`già fatto` ed esce con 0.

## Fuori perimetro, per scelta

- **Non scrive il `.env`**, nemmeno uno scheletro: lo si compila a mano. Il verdetto
  resta no finché `shared/.env` non esiste con `APP_KEY` valorizzata.
- **Non tocca i cron**: stanno nel pannello.
- **Non cancella `current` se è una directory.**
- **Non cancella `shared/000-legacy.tar.gz`.**
- **Non crea dominio, database, chiave SSH né `deploy.yml`.**
- **Nessuna suite di test**: `ci-workflows` non ne ha una, e lo script girerà una
  manciata di volte. Il prezzo è pagato dalla loquacità di `recon`.
