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

Dal proprio computer, dalla cartella di questo repository, senza copiare niente
sul server. Un esempio completo:

```sh
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- recon --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
```

Pezzo per pezzo:

| pezzo | cosa scrivere | nell'esempio |
|---|---|---|
| `ssh -p 2222` | la porta SSH del server; `-p` si omette se è la 22 | `2222` |
| `dominio@server.hosting.it` | utente cPanel del dominio e host SSH: gli stessi che andranno nei secret `SSH_USER` e `SSH_HOST` | |
| `'sh -s' --` | sempre uguale, fra apici: dice al server di eseguire lo script che arriva da stdin, passandogli gli argomenti che seguono | |
| fase | una fra `recon`, `bridge`, `shared`, `legacy`, `cleanup` (vedi sotto quale e quando) | `recon` |
| modalità | `--from-existing` se sul dominio c'è già il sito in linea da migrare, `--new` se il dominio è appena creato e vuoto | `--from-existing` |
| BASE | la cartella del dominio, percorso assoluto: quella che **contiene** `artisan` nel sito piatto, o quella in cui cPanel ha creato `current/` su un dominio nuovo. Non `public/`, non `current/` | `/home/dominio/dominio.it` |
| opzioni | facoltative, vedi la tabella qui sotto; vanno dopo BASE | nessuna |
| `< scripts/setup-releases.sh` | sempre uguale: è lo script che viene mandato al server. Il percorso è relativo alla cartella da cui lanci il comando | |

Per trovare BASE: dal pannello cPanel, **Domini**, la colonna del document root.
Se il document root è `/home/dominio/dominio.it/public`, BASE è
`/home/dominio/dominio.it`. Se si è in dubbio, `recon` non modifica niente:
lanciarlo su un percorso sbagliato mostra solo che dentro non c'è il sito.

Fra una fase e l'altra cambia solo la parola della fase; modalità e BASE restano
le stesse per tutta la migrazione.

Non è una GitHub Action perché gira **prima** che l'Environment e i secret SSH
esistano. Siccome lo script arriva al server da stdin, nessuna fase chiede niente:
ognuna è un comando a sé.

| opzione | quando serve | default |
|---|---|---|
| `--url https://dominio.it` | se `APP_URL` nel `.env` non è l'indirizzo pubblico del sito (es. `http://localhost`), oppure in `--new` prima che il `.env` esista | `APP_URL` del `.env` |
| `--php-bin /opt/cpanel/ea-php84/root/usr/bin/php` | in `recon`, per verificare un `PHP_BIN` preciso, o quando `recon` dice che non riesce a determinarlo | il PHP del dominio |
| `--health-path /login` | se la home risponde 4xx anche con il sito sano (es. protetta da password): va indicata una pagina che risponde 2xx o 3xx | `/` |
| `--timeout 300` | se la sonda di `legacy` o `cleanup` scade prima che PHP veda la release | `150` secondi |
| `--no-color` | se l'output va salvato in un file o incollato altrove | colori attivi |

Un'opzione con valore si scrive con uno spazio in mezzo:
`... cleanup --from-existing /home/dominio/dominio.it --url https://dominio.it --timeout 300 < scripts/setup-releases.sh`.

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

Con i valori dell'esempio sopra. Ogni riga si lancia quando la precedente è finita
bene, e le righe con `#` sono passi da fare a mano:

```sh
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- recon   --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- bridge  --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
# pannello cPanel: document root del dominio -> /home/dominio/dominio.it/current/public
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- shared  --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- legacy  --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- cleanup --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
# pannello cPanel: cron su /home/dominio/dominio.it/current/artisan
ssh -p 2222 dominio@server.hosting.it 'sh -s' -- recon   --from-existing /home/dominio/dominio.it < scripts/setup-releases.sh
# ripetere recon finché non dice "pronto per il primo deploy: sì"
# Environment GitHub: scripts/setup-environment.sh (vedi sotto)
# poi il primo deploy, sullo stesso commit già in produzione
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
ssh -p 2222 nuovo@server.hosting.it 'sh -s' -- recon  --new /home/nuovo/nuovo.it < scripts/setup-releases.sh
ssh -p 2222 nuovo@server.hosting.it 'sh -s' -- shared --new /home/nuovo/nuovo.it < scripts/setup-releases.sh
# compilare a mano /home/nuovo/nuovo.it/shared/.env, con APP_KEY, e chmod 600
ssh -p 2222 nuovo@server.hosting.it 'sh -s' -- recon  --new /home/nuovo/nuovo.it < scripts/setup-releases.sh
# ripetere recon finché non dice "pronto per il primo deploy: sì"
# Environment GitHub: scripts/setup-environment.sh (vedi sotto)
```

Il document root si cambia quando si vuole: fino al primo deploy il dominio è rotto
comunque.

## L'Environment GitHub: setup-environment.sh

`scripts/setup-environment.sh` crea l'Environment del progetto e ci scrive le vars e
i secret che chiede il deploy. Gira sul proprio computer, dalla cartella di questo
repository, con la CLI `gh` autenticata da admin del repository del progetto e bash
4.4 o più recente (su macOS: `brew install bash`). Si lancia quando `recon` dice
pronto, prima del primo deploy.

Essere admin del repository non basta se `gh` è autenticato con un fine-grained
token (`github_pat_...`): vede solo quello che gli è stato concesso, e le chiamate
su secret e variabili rispondono `Resource not accessible by personal access token
(HTTP 403)`. La strada più semplice è rifare il login con il browser, che dà un
token con scope `repo`:

```sh
gh auth login --web
```

In alternativa si aggiungono al token, per il repository del progetto,
Administration e Environments in lettura e scrittura, Secrets e Variables in
lettura. Lo script controlla i permessi prima di fare qualunque cosa, e se mancano
lo dice.

```sh
scripts/setup-environment.sh --repo ITinternalDiMartino/progetto --env production \
  --ssh dominio@server.hosting.it --port 2222 --base /home/dominio/dominio.it \
  --key ~/.ssh/deploy_progetto
```

| argomento | cosa ci va |
|---|---|
| `--repo` | il repository del **progetto**, non `ci-workflows`, nella forma `ORGANIZZAZIONE/NOME` |
| `--env` | il nome dell'Environment, lo stesso di `environment:` nel `deploy.yml` del progetto (es. `production`, `qat`) |
| `--ssh`, `--port` | come per `setup-releases.sh`. Anche un alias di `~/.ssh/config` va bene: nei secret finiscono host, porta e utente risolti |
| `--base` | la stessa BASE di `setup-releases.sh` |
| `--key` | il file della **chiave privata di deploy**, già esistente e già autorizzata sul server, senza passphrase |
| `--php-bin` | facoltativo: `PHP_BIN` al posto di quello che dice il server |
| `--app-name` | facoltativo: `APP_NAME` al posto di quello di `shared/.env` |
| `--dry-run` | mostra cosa farebbe, accanto ai valori già presenti, e si ferma |
| `--yes` | non chiede conferma |

Da dove vengono i valori:

- **vars**: le calcola il server con la fase `vars` di `setup-releases.sh`, che
  stampa `NOME=valore` e non modifica niente. `PHP_BIN` è quindi il PHP del
  dominio, come in `recon`;
- **`SSH_HOST`, `SSH_USER`, `SSH_PORT`**: da `--ssh` e `--port`, risolti da `ssh -G`;
- **`SSH_KNOWN_HOSTS`**: le righe dell'host prese dal proprio `known_hosts`, cioè la
  chiave che si è già accettata collegandosi. Se l'host non c'è, lo script si ferma:
  ci si collega una volta a mano, si confronta l'impronta con quella del pannello e
  si rilancia. Non usa `ssh-keyscan`, che si fida di chiunque risponda in quel
  momento;
- **`SSH_PRIVATE_KEY`**: il file di `--key`, con il newline finale aggiunto se manca
  (senza, il runner fallisce con `error in libcrypto`). La chiave **non** viene
  generata né autorizzata dallo script.

Prima di scrivere si collega al server con la chiave di deploy **alle stesse
condizioni del runner**: nessuna `~/.ssh/config`, solo quella chiave, solo quelle
righe di `known_hosts`, `BatchMode`. Se il server rifiuta la chiave, stampa la
chiave pubblica da autorizzare in cPanel (SSH Access → Manage SSH Keys → Import Key,
poi Authorize) e non scrive niente.

Il `GH_TOKEN` non lo tocca, perché di solito è un secret dell'organizzazione:
controlla solo che il repository lo veda, e se non lo trova lo dice. Lo script si
può rilanciare: le vars uguali restano come sono, quelle diverse vengono aggiornate
e i secret sovrascritti.

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

**`vars`**, senza modalità, stampa le vars dell'Environment come `NOME=valore`, e
nient'altro. Non modifica niente: la usa `setup-environment.sh`.

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
3. dà ad Apache l'accesso che ha in una release del deploy (`o+x` sulla radice
   della copia, `o+rX` su `public/`). `tar -p` ha copiato alla radice il modo di
   `$BASE`, che su cPanel è spesso `750` con gruppo `nobody`: il modo si copia, il
   gruppo no, perché lo assegna solo root. Senza questo passo Apache risponde
   `403 Server unable to read htaccess file`. Poi ricrea i collegamenti con target
   relativo (`ln -srfT`) verso `shared/`: i
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
L'attesa normale è un 404, il file che nel posto vecchio non c'è: qualunque altra
risposta senza token (403, 5xx, redirect, nessuna connessione) non si sistema
aspettando, e `legacy` ripristina subito invece di lasciare il sito in errore fino
al timeout. Tornato il token, `--health-path` deve rispondere 2xx o 3xx.

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
