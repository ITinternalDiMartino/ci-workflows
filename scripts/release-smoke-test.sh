#!/bin/sh
# Smoke test della Release: risponde alla domanda "la Release nuova è davvero in
# linea?". Aspetta che PHP serva il marcatore della Release attesa, classifica
# ogni risposta in un verdetto, poi controlla health path e home.
#
# Il marcatore è un file PHP con un nome fisso da sonda, /__probe-release.php,
# che stampa il nome della Release. Esiste solo dentro la public/ della Release
# nuova: finché la realpath cache di PHP (default 120s) risolve current nella
# Release precedente il file non c'è e la risposta è un 404. Un file statico non
# basterebbe: il web server lo servirebbe appena current cambia, e health path e
# home misurerebbero ancora il codice vecchio.
#
# È POSIX sh, senza bash: sul server cPanel la shell non interattiva è minima.
# Si usa in due modi, con lo stesso interface:
#
#   come script     sh release-smoke-test.sh --url URL --release NOME [opzioni]
#   come funzione   concatenato prima di un altro script, che chiama
#                   release_smoke_test --url URL --release NOME [opzioni]
#                   (così arriva al server su stdin: 'sh -s')
#
# Opzioni:
#   --url URL              URL base del sito, già risolto (APP_URL)
#   --release NOME         nome della Release attesa nel marcatore
#   --health-path PATH     percorso che deve rispondere 200 (default: /up)
#   --timeout SECONDI      attesa massima del marcatore (default: 150)
#   --interval SECONDI     pausa fra un tentativo e l'altro (default: 10)
#   --redirects MODO       'follow': health path e home seguono i redirect, come
#                          con smoke-from 'runner'. 'none': nessun redirect
#                          seguito, come con smoke-from 'server' (default: follow)
#   --decisions PERCORSO   decisions-script che decide i verdetti al posto del
#                          default (contratto sotto)
#   --marker-dir DIR       la public/ della Release: il module scrive il
#                          marcatore in DIR e lo rimuove all'uscita, anche se
#                          fallisce o viene interrotto (INT, TERM, HUP, PIPE; il
#                          segnale interrompe anche la pausa fra due tentativi).
#                          Senza, il marcatore deve già essere servito
#   --marker-host HOST     DIR è sul server HOST, raggiunto con ssh: il module
#                          invia se stesso e scrive e rimuove il marcatore là
#                          (smoke-from 'runner'). Solo lanciato come script, e
#                          con --marker-dir. Se la scrittura fallisce l'esito è
#                          unavailable; se fallisce la rimozione, che ha un
#                          ConnectTimeout di 5s, è un avviso e l'esito non cambia
#   --remove-marker        non fa lo smoke test: rimuove soltanto il marcatore da
#                          --marker-dir (con o senza --marker-host) ed esce con 0,
#                          anche se non c'è o se non riesce (con un avviso). È la
#                          pulizia di chi non può contare sulle trap del module
#   --github               errori come annotazioni di GitHub Actions (::error::,
#                          ::warning::), e con GITHUB_OUTPUT impostato aggiunge
#                          "url=<url usato davvero>" a quel file, qualunque esito
#
# Verdetti sul marcatore. Un 404 o una risposta assente (codice 000) sono sempre
# attesa, con verdetto no-response, e non arrivano mai al decisions-script: il
# 404 è la pagina della Release precedente mentre la cache si aggiorna. Le altre
# risposte le classifica il decisions-script, se c'è, altrimenti il default:
#   match                  la Release attesa è in linea: si passa alla salute
#   mismatch, no-response  si ritenta fino al timeout
#   challenged, html-page  definitivi: aspettare non li sistema
#   qualunque altro        si ritenta, come mismatch
# Il default dà challenged a un 403 o 503 con una pagina di challenge (firme in
# pagina_di_challenge), html-page a una pagina HTML servita con 200, match o
# mismatch confrontando il corpo con la Release, no-response a un corpo vuoto.
#
# Redirect sul marcatore. Se --url è in http:// e il marcatore redirige allo
# stesso host e allo stesso percorso in https://, il module passa a https://
# per tutto il resto (marcatore, health path, home), con qualunque --redirects:
# lascia una nota che consiglia di aggiornare APP_URL e stampa
# "release-smoke-test-url: <url>". Con --redirects none, un redirect che resta
# dopo questo passaggio (altro host o altro percorso) è definitivo, con esito
# redirect, e non arriva al decisions-script. Con --redirects follow quel
# redirect si classifica come ogni altra risposta, come prima.
#
# Contratto del decisions-script: argomenti, stdin e uscita sono quelli che il
# deploy usava già; diverso è solo che 404 e 000 non gli arrivano più.
#   <script> smoke-marker <release>              corpo su stdin, stampa un verdetto
#   <script> smoke-health <codice-health> <codice-home>
#                                                esce non zero e stampa cosa è fallito
#
# Uscita: l'ultima riga è "release-smoke-test: <esito>", con esito fra online,
# timeout, challenged, html-page, redirect, unhealthy, unavailable (manca curl o
# il marcatore non si può scrivere), usage. Exit code 0 solo con online, 2 per
# un uso sbagliato, 1 altrimenti.
#
# Il marcatore lo scrive e lo rimuove solo il module, in entrambe le modalità
# smoke-from: nome e contenuto del file stanno solo qui.
#
# Le funzioni pubbliche, per chi arriva concatenato dopo il module
# (setup-releases.sh): sono quelle che lo smoke test usa al suo interno, così
# richieste, passaggio a https e criterio di salute restano uno solo.
#   release_smoke_risposta URL           GET senza redirect: il corpo, poi una
#                                        riga "<codice> <destinazione redirect>"
#   release_smoke_codice URL [follow]    il solo codice HTTP (000 senza risposta)
#   release_smoke_https URL              l'URL da usare: https:// se il dominio
#                                        lo forza (stesso host e percorso)
#   release_smoke_salute HEALTH_PATH CODICE_HEALTH CODICE_HOME [DECISIONS]
#                                        falso, con cosa è fallito, se il sito
#                                        non è sano
# Lo script concatenato non deve ridefinire RELEASE_SMOKE_MARKER né le funzioni
# release_smoke_*: sono gli unici nomi che il module mette in comune.

# il nome del file, che è anche il percorso servito sotto l'URL del sito
RELEASE_SMOKE_MARKER='__probe-release.php'

# Interna: scrive (scrivi DIR RELEASE) o rimuove (rimuovi DIR) il marcatore in
# DIR. La chiama lo smoke test, qui o sul server via ssh con --marker-host.
release_smoke_marker() (
  file="$2/$RELEASE_SMOKE_MARKER"
  case "$1" in
    scrivi)
      # il nome finisce in una stringa PHP fra apici singoli
      nome="$(printf '%s' "$3" | sed "s/[\\\\']/\\\\&/g")"
      printf "<?php echo '%s';\n" "$nome" > "$file"
      ;;
    rimuovi) rm -f "$file" ;;
    *) return 2 ;;
  esac
)

# Una richiesta GET che non segue redirect: stampa il corpo, poi un'ultima riga
# "<codice> <destinazione del redirect>" (vuota se non c'è redirect). Con -w
# curl stampa 000 anche quando la richiesta non va a buon fine. stderr di curl
# non va silenziato: quando non si connette, la sua riga è l'unica diagnosi.
release_smoke_risposta() (
  risposta="$(curl -sS --max-time 10 -w '\n%{http_code} %{redirect_url}' "$1" || true)"
  ultima="$(printf '%s\n' "$risposta" | tail -n 1)"
  case "${ultima%% *}" in [0-9][0-9][0-9]) ;; *) ultima='000 ' ;; esac
  printf '%s\n%s\n' "$(printf '%s\n' "$risposta" | sed '$d')" "$ultima"
)

# Il solo codice HTTP di una GET, seguendo i redirect con 'follow' (default:
# 'none'). 000 se non risponde.
release_smoke_codice() (
  if [ "${2:-none}" = follow ]; then
    c="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$1" || true)"
  else
    c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true)"
  fi
  case "$c" in [0-9][0-9][0-9]) echo "$c" ;; *) echo 000 ;; esac
)

# APP_URL in http:// su un dominio che forza HTTPS: si passa a https:// solo se
# il redirect porta allo stesso host e allo stesso percorso, cioè è il dominio e
# non un altro sito. Argomenti: URL, codice, destinazione del redirect e
# percorso richiesto. Stampa l'URL in https:// ed è vero se il passaggio vale.
release_smoke_https_forzato() (
  case "$1" in http://*) ;; *) return 1 ;; esac
  case "$2" in 3??) ;; *) return 1 ;; esac
  [ "$3" = "https://${1#http://}$4" ] || return 1
  printf '%s\n' "https://${1#http://}"
)

# L'URL da usare per URL: la sua versione https:// se il dominio la forza,
# altrimenti URL stesso, senza la barra finale.
release_smoke_https() (
  url="${1%/}"
  ultima="$(release_smoke_risposta "$url/$RELEASE_SMOKE_MARKER" 2> /dev/null | tail -n 1)"
  release_smoke_https_forzato "$url" "${ultima%% *}" "${ultima#* }" "/$RELEASE_SMOKE_MARKER" ||
    printf '%s\n' "$url"
)

# Il verdetto su health path e home, dati i due codici: il decisions-script se
# c'è, altrimenti il default (health path 200, home sotto 400). Stampa cosa è
# fallito ed è falso se il sito non è sano.
release_smoke_salute() (
  if [ -n "${4:-}" ]; then
    "$4" smoke-health "$2" "$3"
    return
  fi
  fallito=''
  [ "$2" = 200 ] || fallito="$1=$2"
  [ "$3" -lt 400 ] || fallito="${fallito:+$fallito }/=$3"
  [ -z "$fallito" ] || {
    printf '%s\n' "$fallito"
    return 1
  }
)

# Il corpo gira in una subshell: variabili, funzioni interne, trap ed exit
# restano dentro la funzione, anche quando a chiamarla è uno script concatenato.
# Concatenato il module non conosce il proprio file: niente --marker-host.
release_smoke_test() (
  release_smoke_test_nel_processo '' "$@"
)

# Il corpo dello smoke test, che gira nel processo che lo chiama: ci installa le
# sue trap e ne esce con exit. Interna: la chiama direttamente solo questo file
# lanciato come script (in fondo). Uno script concatenato usa release_smoke_test.
# Il primo argomento è il file del module, vuoto quando è concatenato: con
# --marker-host il module lo invia al server per scrivere il marcatore.
release_smoke_test_nel_processo() {
  sorgente="$1"
  shift
  marker_path="/$RELEASE_SMOKE_MARKER"
  url=''
  release=''
  health_path='/up'
  timeout=150
  interval=10
  redirects='follow'
  decisions=''
  marker_dir=''
  marker_host=''
  solo_rimozione=''
  github=''
  marcatore_scritto=''
  pausa=''

  errore() {
    if [ -n "$github" ]; then
      echo "::error::$*"
    else
      echo "errore: $*"
    fi
  }

  avviso() {
    if [ -n "$github" ]; then
      echo "::warning::$*"
    else
      echo "attenzione: $*"
    fi
  }

  nota() {
    if [ -n "$github" ]; then
      echo "::notice::$*"
    else
      echo "nota: $*"
    fi
  }

  esito() {
    echo "release-smoke-test: $1"
  }

  uso() {
    errore "release-smoke-test: $*"
    esito usage
    exit 2
  }

  # ssh unisce gli argomenti in una riga che la shell remota rilegge: ogni
  # valore va fra apici singoli.
  apici() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  }

  # Il marcatore, dovunque sia la public/ della Release. Due adapter: senza
  # --marker-host il filesystem di qui; con --marker-host il server, via ssh,
  # dove il module invia se stesso e chiama release_smoke_marker. Primo argomento
  # scrivi o rimuovi; gli altri sono opzioni di ssh, prima dell'host.
  marcatore() {
    op="$1"
    shift
    if [ -z "$marker_host" ]; then
      release_smoke_marker "$op" "$marker_dir" "$release" 2> /dev/null
      return
    fi
    # shellcheck disable=SC2029 # gli argomenti si espandono qui, già fra apici
    { cat "$sorgente"; printf '%s\n' 'release_smoke_marker "$@"'; } |
      ssh "$@" "$marker_host" "sh -s -- $(apici "$op") $(apici "$marker_dir") $(apici "$release")"
  }

  # dove sta il marcatore, per i messaggi
  dove() {
    printf '%s' "${marker_host:+$marker_host:}$marker_dir"
  }

  # La rimozione ha un timeout di connessione breve: quando lo step viene
  # annullato, il runner concede pochi secondi prima di uccidere tutto.
  rimuovi_marcatore() {
    marcatore rimuovi -o ConnectTimeout=5
  }

  while [ $# -gt 0 ]; do
    case "$1" in
      --github)
        github=1
        shift
        continue
        ;;
      --remove-marker)
        solo_rimozione=1
        shift
        continue
        ;;
      --url | --release | --health-path | --timeout | --interval | --redirects | --decisions | --marker-dir | --marker-host)
        [ $# -ge 2 ] || uso "$1 vuole un valore"
        ;;
      *) uso "argomento sconosciuto: $1" ;;
    esac
    case "$1" in
      --url) url="$2" ;;
      --release) release="$2" ;;
      --health-path) health_path="$2" ;;
      --timeout) timeout="$2" ;;
      --interval) interval="$2" ;;
      --redirects) redirects="$2" ;;
      --decisions) decisions="$2" ;;
      --marker-dir) marker_dir="$2" ;;
      --marker-host) marker_host="$2" ;;
    esac
    shift 2
  done

  if [ -n "$marker_host" ]; then
    [ -n "$marker_dir" ] || uso "--marker-host vuole --marker-dir: la public/ della Release sul server"
    [ -n "$sorgente" ] || uso "--marker-host vale solo lanciando il module come script: concatenato, il module gira già sul server e basta --marker-dir"
  fi

  # Sola rimozione, per la pulizia dopo lo smoke test: ripetibile, e una
  # rimozione non riuscita è un avviso, mai un errore.
  if [ -n "$solo_rimozione" ]; then
    [ -n "$marker_dir" ] || uso "--remove-marker vuole --marker-dir"
    rimuovi_marcatore || avviso "non riesco a rimuovere il marcatore da $(dove)"
    exit 0
  fi

  [ -n "$url" ] || uso "manca --url"
  [ -n "$release" ] || uso "manca --release"
  case "$timeout" in '' | *[!0-9]*) uso "--timeout vuole un numero di secondi, non '$timeout'" ;; esac
  case "$interval" in '' | *[!0-9]*) uso "--interval vuole un numero di secondi, non '$interval'" ;; esac
  case "$redirects" in follow | none) ;; *) uso "--redirects vale '$redirects': gli unici valori ammessi sono 'follow' e 'none'" ;; esac
  if [ -n "$decisions" ]; then
    [ -f "$decisions" ] || uso "il decisions-script '$decisions' non esiste"
    [ -x "$decisions" ] || uso "il decisions-script '$decisions' non è eseguibile"
    # senza una barra il nome verrebbe cercato nel PATH
    case "$decisions" in */*) ;; *) decisions="./$decisions" ;; esac
  fi
  # con --marker-host la directory è sul server: lì la verifica è la scrittura
  if [ -n "$marker_dir" ] && [ -z "$marker_host" ]; then
    [ -d "$marker_dir" ] || uso "--marker-dir '$marker_dir' non è una directory"
  fi
  url="${url%/}"

  # Chiude lo smoke test: rimuove il marcatore, se è stato scritto, pubblica in
  # GITHUB_OUTPUT l'URL usato davvero (con --github) e stampa l'esito, che resta
  # l'ultima riga. Una rimozione non riuscita non cambia l'esito.
  termina() {
    trap - EXIT
    if [ -n "$marcatore_scritto" ] && ! rimuovi_marcatore; then
      avviso "non riesco a rimuovere il marcatore da $(dove): resta servito finché qualcuno non lo rimuove (--remove-marker)"
    fi
    if [ -n "$github" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "url=$url" >> "$GITHUB_OUTPUT"
    fi
    esito "$1"
    exit "$2"
  }

  # Il marcatore non deve restare servito: si rimuove all'uscita, comunque vada.
  # Una connessione SSH che cade arriva come SIGPIPE alla prima scrittura, quindi
  # anche PIPE; nei gestori dei segnali niente output, che rischierebbe un altro
  # SIGPIPE. Il segnale interrompe anche la pausa fra due tentativi (sleep in
  # background più wait): chi annulla lo step non aspetta la fine della pausa.
  # Da concatenato il corpo gira nella subshell di release_smoke_test: queste
  # trap non toccano lo script a cui il module è concatenato. Lanciato come
  # script, sono le trap del processo dello script.
  # shellcheck disable=SC2329 # chiamata dalla trap qui sotto
  interrotto() {
    trap - EXIT
    [ -z "$pausa" ] || kill "$pausa" 2> /dev/null
    [ -z "$marcatore_scritto" ] || rimuovi_marcatore > /dev/null 2>&1
    exit 130
  }
  trap '[ -z "$marcatore_scritto" ] || rimuovi_marcatore > /dev/null 2>&1' EXIT
  trap interrotto INT TERM HUP PIPE

  if ! command -v curl > /dev/null 2>&1; then
    errore "manca curl: la misura ha bisogno di un client HTTP"
    termina unavailable 1
  fi

  if [ -n "$marker_dir" ]; then
    # segnato prima di scrivere: un segnale a metà scrittura lo rimuove lo stesso
    marcatore_scritto=1
    if ! marcatore scrivi; then
      marcatore_scritto=''
      errore "non riesco a scrivere il marcatore in $(dove)"
      termina unavailable 1
    fi
  fi

  # Imposta codice e corpo della risposta al marcatore, e redirect_verso, la
  # destinazione di un eventuale redirect (vuota se non c'è): curl non lo segue
  # mai, la decisione è del ciclo di attesa.
  leggi_marcatore() {
    risposta="$(release_smoke_risposta "$url$marker_path")"
    ultima_riga="$(printf '%s\n' "$risposta" | tail -n 1)"
    codice="${ultima_riga%% *}"
    redirect_verso="${ultima_riga#* }"
    corpo="$(printf '%s\n' "$risposta" | sed '$d')"
  }

  # Vero se il passaggio a https:// è avvenuto.
  https_se_forzato() {
    nuovo="$(release_smoke_https_forzato "$url" "$codice" "$redirect_verso" "$marker_path")" || return 1
    url="$nuovo"
    nota "http:// redirige su https://: smoke test su $url (conviene APP_URL=$url nel .env)"
    echo "release-smoke-test-url: $url"
  }

  # Firme delle pagine di challenge delle protezioni anti-bot più comuni, cercate
  # senza distinguere maiuscole nel corpo di un 403 o 503:
  #   Cloudflare      "Just a moment...", /cdn-cgi/challenge-platform/,
  #                   "Attention Required! | Cloudflare"
  #   Sucuri          "Sucuri WebSite Firewall"
  #   Imperva         _Incapsula_Resource
  #   Imunify360      "imunify360" (bot-protection dei cPanel)
  #   DDoS-Guard      "ddos-guard"
  pagina_di_challenge() {
    printf '%s' "$corpo" | grep -qiE \
      'just a moment\.\.\.|/cdn-cgi/challenge-platform/|attention required! \| cloudflare|sucuri website firewall|_incapsula_resource|imunify360|ddos-guard'
  }

  classifica() {
    if [ -n "$decisions" ]; then
      printf '%s' "$corpo" | "$decisions" smoke-marker "$release" || true
      return
    fi
    case "$codice" in
      403 | 503)
        if pagina_di_challenge; then
          echo challenged
          return
        fi
        ;;
      # il marcatore è testo semplice: una pagina HTML con 200 è il vhost che
      # serve altro, non una Release vecchia che sta per cambiare
      200)
        if printf '%s' "$corpo" | grep -qiE '<!doctype html|<(html|head|body)([[:space:]>]|$)'; then
          echo html-page
          return
        fi
        ;;
    esac
    servita="$(printf '%s' "$corpo" | tr -d '[:space:]')"
    if [ -z "$servita" ]; then
      echo no-response
    elif [ "$servita" = "$release" ]; then
      echo match
    else
      echo mismatch
    fi
  }

  # Polling del marcatore: dopo lo swap la cache dei path può far servire la
  # Release precedente ancora per un po'. Attesa deterministica invece di un
  # test a volte rosso.
  fine=$(($(date +%s) + timeout))
  while :; do
    leggi_marcatore
    # il passaggio a https:// avviene una volta sola: si rilegge subito
    if https_se_forzato; then
      leggi_marcatore
    fi
    # Senza redirect seguiti, uno che resta dopo il passaggio a https:// porta
    # fuori dall'URL sotto test: aspettare non lo sposta.
    if [ "$redirects" = none ]; then
      case "$codice" in
        3??)
          errore "il marcatore riceve un redirect (HTTP $codice verso ${redirect_verso:-destinazione assente}): con smoke-from 'server' i redirect non si seguono. Controlla APP_URL ($url)"
          termina redirect 1
          ;;
      esac
    fi
    case "$codice" in
      404 | 000) verdetto=no-response ;;
      *) verdetto="$(classifica)" ;;
    esac
    case "$verdetto" in
      match)
        echo "release in linea: $release"
        break
        ;;
      # Verdetti definitivi: il sito non sta servendo il marcatore e non
      # inizierà da sé, quindi ritentare è tempo buttato.
      challenged)
        errore "una protezione anti-bot risponde al posto del marcatore. Da 'runner' è attesa su alcuni hosting: prova smoke-from 'server'. Da 'server' significa che la misura via HTTP non è utilizzabile su questa destinazione"
        termina challenged 1
        ;;
      html-page)
        errore "risponde una pagina HTML invece del marcatore: questo vhost non serve la Release ($url non punta alla public/ della Release, o ${marker_path#/} non c'è)"
        termina html-page 1
        ;;
    esac

    if [ "$(date +%s)" -ge "$fine" ]; then
      errore "dopo ${timeout}s il marcatore non è quello della release $release (verdetto: $verdetto, HTTP $codice)"
      termina timeout 1
    fi
    echo "marcatore: $verdetto (HTTP $codice), riprovo fra ${interval}s"
    sleep "$interval" &
    pausa=$!
    wait "$pausa"
    pausa=''
  done

  # L'health path fa il boot completo del framework ma non attraversa routing,
  # middleware e manifest di Vite: per quello serve la home, che redirige al
  # login o risponde direttamente.
  codice_health="$(release_smoke_codice "$url$health_path" "$redirects")"
  codice_home="$(release_smoke_codice "$url/" "$redirects")"
  echo "$health_path → $codice_health · / → $codice_home"

  if ! falliti="$(release_smoke_salute "$health_path" "$codice_health" "$codice_home" "$decisions")"; then
    errore "smoke test fallito: $falliti"
    termina unhealthy 1
  fi

  termina online 0
}

# Lanciato come script, e non concatenato a un altro, esegue subito: il corpo
# gira nel processo dello script, senza la subshell della funzione. Così chi
# annulla lo script con un segnale al solo suo processo (lo step dell'action con
# smoke-from 'runner') raggiunge il processo che fa il lavoro, invece di
# lasciarlo vivo fino al timeout in una subshell figlia.
case "${0##*/}" in
  release-smoke-test.sh) release_smoke_test_nel_processo "$0" "$@" ;;
esac
