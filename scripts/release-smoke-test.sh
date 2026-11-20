#!/bin/sh
# Smoke test della Release: risponde alla domanda "la Release nuova è davvero in
# linea?". Aspetta che il sito serva il marcatore della Release attesa, classifica
# ogni risposta in un verdetto, poi controlla health path e home.
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
#   --github               errori come annotazioni di GitHub Actions (::error::)
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
# Contratto del decisions-script: argomenti, stdin e uscita sono quelli che il
# deploy usava già; diverso è solo che 404 e 000 non gli arrivano più.
#   <script> smoke-marker <release>              corpo su stdin, stampa un verdetto
#   <script> smoke-health <codice-health> <codice-home>
#                                                esce non zero e stampa cosa è fallito
#
# Uscita: l'ultima riga è "release-smoke-test: <esito>", con esito fra online,
# timeout, challenged, html-page, unhealthy, unavailable (manca curl), usage.
# Exit code 0 solo con online, 2 per un uso sbagliato, 1 altrimenti.

# Il corpo è una subshell: variabili ed exit restano dentro la funzione, anche
# quando a chiamarla è uno script concatenato.
release_smoke_test() (
  marker_path='/release.txt'
  url=''
  release=''
  health_path='/up'
  timeout=150
  interval=10
  redirects='follow'
  decisions=''
  github=''

  errore() {
    if [ -n "$github" ]; then
      echo "::error::$*"
    else
      echo "errore: $*"
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

  while [ $# -gt 0 ]; do
    case "$1" in
      --github)
        github=1
        shift
        continue
        ;;
      --url | --release | --health-path | --timeout | --interval | --redirects | --decisions)
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
    esac
    shift 2
  done

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
  if ! command -v curl > /dev/null 2>&1; then
    errore "manca curl: la misura ha bisogno di un client HTTP"
    esito unavailable
    exit 1
  fi
  url="${url%/}"

  # Imposta codice e corpo della risposta al marcatore. stderr di curl non va
  # silenziato: quando non si connette, la sua riga è l'unica diagnosi. Con -w
  # curl stampa 000 anche quando la richiesta non va a buon fine.
  leggi_marcatore() {
    risposta="$(curl -sS --max-time 10 -w '\n%{http_code}' "$url$marker_path" || true)"
    codice="$(printf '%s\n' "$risposta" | tail -n 1)"
    corpo="$(printf '%s\n' "$risposta" | sed '$d')"
    case "$codice" in [0-9][0-9][0-9]) ;; *) codice=000 ;; esac
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

  codice_http() {
    if [ "$redirects" = follow ]; then
      c="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$1" || true)"
    else
      c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true)"
    fi
    case "$c" in [0-9][0-9][0-9]) echo "$c" ;; *) echo 000 ;; esac
  }

  # Polling del marcatore: dopo lo swap la cache dei path può far servire la
  # Release precedente ancora per un po'. Attesa deterministica invece di un
  # test a volte rosso.
  fine=$(($(date +%s) + timeout))
  while :; do
    leggi_marcatore
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
        esito challenged
        exit 1
        ;;
      html-page)
        errore "risponde una pagina HTML invece del marcatore: questo vhost non serve la Release ($url non punta alla public/ della Release, o ${marker_path#/} non c'è)"
        esito html-page
        exit 1
        ;;
    esac

    if [ "$(date +%s)" -ge "$fine" ]; then
      errore "dopo ${timeout}s il marcatore non è quello della release $release (verdetto: $verdetto, HTTP $codice)"
      esito timeout
      exit 1
    fi
    echo "marcatore: $verdetto (HTTP $codice), riprovo fra ${interval}s"
    sleep "$interval"
  done

  # L'health path fa il boot completo del framework ma non attraversa routing,
  # middleware e manifest di Vite: per quello serve la home, che redirige al
  # login o risponde direttamente.
  codice_health="$(codice_http "$url$health_path")"
  codice_home="$(codice_http "$url/")"
  echo "$health_path → $codice_health · / → $codice_home"

  if [ -n "$decisions" ]; then
    if ! falliti="$("$decisions" smoke-health "$codice_health" "$codice_home")"; then
      errore "smoke test fallito: $falliti"
      esito unhealthy
      exit 1
    fi
  else
    fallito=''
    [ "$codice_health" = 200 ] || fallito="$health_path=$codice_health"
    [ "$codice_home" -lt 400 ] || fallito="${fallito:+$fallito }/=$codice_home"
    if [ -n "$fallito" ]; then
      errore "smoke test fallito: $fallito"
      esito unhealthy
      exit 1
    fi
  fi

  esito online
)

# Lanciato come script, e non concatenato a un altro, esegue subito.
case "${0##*/}" in
  release-smoke-test.sh) release_smoke_test "$@" ;;
esac
