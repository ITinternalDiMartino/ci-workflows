#!/bin/sh
# Suite del module di smoke test della Release (scripts/release-smoke-test.sh).
#
# Esercita il module solo dal suo interface: lo lancia come script contro un
# server HTTP locale con risposte programmate (http-server.py) e controlla esito,
# exit code e messaggi. Nessun mock di curl.
#
# Uso: scripts/tests/release-smoke-test.test.sh
# Ambiente:
#   TEST_SHELL  la shell con cui lanciare il module (default: dash se c'è,
#               altrimenti sh): il module deve girare su una shell POSIX minima
#
# Dipendenze: python3, curl, openssl.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/../release-smoke-test.sh"
SERVER="$HERE/http-server.py"
if [ -z "${TEST_SHELL:-}" ]; then
  if command -v dash > /dev/null 2>&1; then TEST_SHELL='dash'; else TEST_SHELL='sh'; fi
fi

WORK="$(mktemp -d)"
SERVER_PID=''
stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2> /dev/null
    wait "$SERVER_PID" 2> /dev/null
    SERVER_PID=''
  fi
}
trap 'stop_server; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

# Certificato autofirmato per 127.0.0.1: il server di test risponde anche in
# HTTPS sulla stessa porta, e curl si fida di questo certificato attraverso
# CURL_CA_BUNDLE, senza toccare il module.
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" > /dev/null 2>&1; then
  echo "openssl non ha generato il certificato di test" >&2
  exit 1
fi

PASSED=0
FAILED=0
CURRENT_FAILED=''

fail() {
  CURRENT_FAILED=1
  echo "    ✗ $*"
}

# Avvia il server con le rotte in JSON passate come argomento. Imposta URL e
# svuota il registro delle richieste.
serve() {
  stop_server
  printf '%s\n' "$1" > "$WORK/routes.json"
  rm -f "$WORK/port" "$WORK/requests"
  : > "$WORK/requests"
  python3 -I "$SERVER" "$WORK/routes.json" "$WORK/port" "$WORK/requests" \
    "$WORK/cert.pem" "$WORK/key.pem" &
  SERVER_PID=$!
  i=0
  while [ ! -s "$WORK/port" ]; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      echo "il server di test non è partito" >&2
      exit 1
    fi
    sleep 0.05
  done
  PORT="$(cat "$WORK/port")"
  URL="http://127.0.0.1:$PORT"
}

# Lancia il module contro il server, con un'attesa breve fra un tentativo e
# l'altro. Gli argomenti si aggiungono (e possono sostituire) quelli di default.
smoke() {
  OUT="$(CURL_CA_BUNDLE="$WORK/cert.pem" "$TEST_SHELL" "$MODULE" --url "$URL" \
    --release R1 --health-path /up --timeout 2 --interval 1 "$@" 2>&1)"
  RC=$?
}

expect_rc() {
  [ "$RC" = "$1" ] || fail "exit code $RC, atteso $1"
}

expect_out() {
  case "$OUT" in
    *"$1"*) ;;
    *) fail "nell'output manca: $1" ;;
  esac
}

expect_no_out() {
  case "$OUT" in
    *"$1"*) fail "l'output non doveva contenere: $1" ;;
  esac
}

requested() {
  grep -qxF "$1" "$WORK/requests"
}

expect_requested() {
  requested "$1" || fail "$1 non è stato richiesto"
}

expect_not_requested() {
  ! requested "$1" || fail "$1 è stato richiesto"
}

# Un decisions-script finto con il contratto del deploy: registra cosa riceve,
# dà html-page a qualunque corpo HTML (la regola che, se gli arrivasse un 404,
# farebbe fallire il deploy durante l'attesa normale) e un verdetto sconosciuto
# a un corpo che contiene "boh".
DECISIONS="$WORK/decisions.sh"
cat > "$DECISIONS" <<'EOF'
#!/bin/sh
log="$(dirname "$0")/decisions.log"
case "$1" in
  smoke-marker)
    body="$(cat)"
    printf 'smoke-marker %s <%s>\n' "$2" "$body" >> "$log"
    case "$body" in
      *'<html'*) echo html-page; exit 2 ;;
      *challenge*) echo challenged; exit 2 ;;
      *boh*) echo boh; exit 1 ;;
      "$2") echo match ;;
      '') echo no-response; exit 1 ;;
      *) echo mismatch; exit 1 ;;
    esac
    ;;
  smoke-health)
    printf 'smoke-health %s %s\n' "$2" "$3" >> "$log"
    [ "$2" = 200 ] || { echo "salute=$2"; exit 1; }
    echo healthy
    ;;
esac
EOF
chmod +x "$DECISIONS"
DECISIONS_LOG="$WORK/decisions.log"

# il percorso del marcatore: un file PHP con un nome fisso da sonda
MARKER='/__probe-release.php'

# la pagina 404 di Laravel della Release precedente, servita durante l'attesa
NOT_FOUND='{"status": 404, "body": "<!DOCTYPE html><html><title>Not Found</title></html>"}'
HEALTHY='"/up": [{"status": 200, "body": "ok"}], "/": [{"status": 200, "body": "home"}]'

# --- marcatore servito da PHP -------------------------------------------------

# PUBLIC è la public/ della Release che PHP risolve: il server di test serve il
# marcatore da lì come farebbe PHP, con un 404 finché il file non c'è.
PUBLIC="$WORK/public"
fresh_public() {
  rm -rf "$PUBLIC"
  mkdir -p "$PUBLIC"
}
PHP_MARKER='"'"$MARKER"'": [{"php": "'"$PUBLIC$MARKER"'"}]'

expect_public_empty() {
  [ -z "$(ls -A "$PUBLIC")" ] || fail "nella public/ della Release è rimasto: $(ls -A "$PUBLIC")"
}

# Subito dopo lo swap il web server serve già i file statici della Release nuova,
# mentre PHP risolve ancora current nella Release precedente (realpath cache),
# dove il marcatore PHP non esiste. Un marcatore statico darebbe match qui, e
# health path e home misurerebbero il codice vecchio.
test_static_marker_does_not_mean_online() {
  fresh_public
  serve '{"/release.txt": [{"status": 200, "body": "R1\n"}], '"$PHP_MARKER"', '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 404)'
  expect_out 'release-smoke-test: timeout'
  expect_not_requested /up
  expect_not_requested /
}

# Il marcatore gestito da fuori, come fa il deploy con smoke-from 'runner': la
# funzione arriva concatenata su stdin, come attraverso SSH.
marker_from_stdin() {
  { cat "$MODULE"; printf '%s\n' 'release_smoke_marker "$@"'; } | "$TEST_SHELL" -s -- "$@"
}

test_marker_managed_from_outside() {
  fresh_public
  serve '{'"$PHP_MARKER"', '"$HEALTHY"'}'
  marker_from_stdin scrivi "$PUBLIC" R1 || fail "scrivi è uscito con $?"
  smoke
  expect_rc 0
  expect_out 'release-smoke-test: online'
  marker_from_stdin rimuovi "$PUBLIC" || fail "rimuovi è uscito con $?"
  expect_public_empty
  # rimuovere un marcatore che non c'è non è un errore: la pulizia è ripetibile
  marker_from_stdin rimuovi "$PUBLIC" || fail "rimuovi senza marcatore è uscito con $?"
}

test_marker_rejects_unknown_command() {
  fresh_public
  OUT="$(marker_from_stdin sposta "$PUBLIC" 2>&1)"
  RC=$?
  expect_rc 2
}

test_marker_written_and_served_by_php() {
  fresh_public
  rm -f "$DECISIONS_LOG"
  serve '{'"$PHP_MARKER"', '"$HEALTHY"'}'
  smoke --marker-dir "$PUBLIC" --decisions "$DECISIONS"
  expect_rc 0
  expect_out 'release-smoke-test: online'
  # il contratto del decisions-script non cambia: riceve il nome della Release
  grep -qxF 'smoke-marker R1 <R1>' "$DECISIONS_LOG" || fail "smoke-marker non ha ricevuto il nome della Release"
  expect_public_empty
}

test_marker_keeps_odd_release_names() {
  fresh_public
  serve '{'"$PHP_MARKER"', '"$HEALTHY"'}'
  smoke --marker-dir "$PUBLIC" --release "R'1\\x"
  expect_rc 0
  expect_out "release in linea: R'1\\x"
}

test_marker_removed_after_unhealthy() {
  fresh_public
  serve '{'"$PHP_MARKER"', "/up": [{"status": 500}], "/": [{"status": 200}]}'
  smoke --marker-dir "$PUBLIC"
  expect_rc 1
  expect_out 'release-smoke-test: unhealthy'
  expect_public_empty
}

test_marker_removed_after_timeout() {
  fresh_public
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  smoke --marker-dir "$PUBLIC"
  expect_rc 1
  expect_out 'release-smoke-test: timeout'
  expect_public_empty
}

test_marker_dir_must_exist() {
  serve '{}'
  smoke --marker-dir "$WORK/assente"
  expect_rc 2
  expect_out 'release-smoke-test: usage'
}

test_marker_dir_not_writable() {
  # root scrive anche dove i permessi non lo consentono
  [ "$(id -u)" != 0 ] || return 0
  fresh_public
  chmod 555 "$PUBLIC"
  serve '{'"$PHP_MARKER"', '"$HEALTHY"'}'
  smoke --marker-dir "$PUBLIC"
  chmod 755 "$PUBLIC"
  expect_rc 1
  expect_out 'non riesco a scrivere il marcatore'
  expect_out 'release-smoke-test: unavailable'
  expect_not_requested "$MARKER"
}

# Lancia il module in un proprio gruppo di processi, con INT e PIPE al default:
# una shell non interattiva avvia i comandi in background con INT ignorato, e un
# segnale ignorato all'avvio non si può più intercettare. Sostituisce con exec la
# shell che lo chiama, così con 'spawn &' $! è il module e il suo gruppo: va
# chiamato solo in background o in una pipeline, mai al posto di un comando.
spawn() {
  exec python3 -I -c '
import os, signal, sys
for s in (signal.SIGINT, signal.SIGPIPE):
    signal.signal(s, signal.SIG_DFL)
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$TEST_SHELL" "$MODULE" --url "$URL" --release R1 --interval 1 --marker-dir "$PUBLIC" "$@"
}

# Senza un'interruzione gestita il marcatore resterebbe fino al timeout (30s):
# deve sparire subito dopo il segnale.
interrupted_by() {
  fresh_public
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  spawn --timeout 30 > "$WORK/out" 2>&1 &
  pid=$!
  i=0
  while [ -z "$(ls -A "$PUBLIC")" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "$(ls -A "$PUBLIC")" ] || fail "il marcatore non è stato scritto"
  kill -s "$1" -- "-$pid" || fail "il gruppo del module non esiste: il segnale non è arrivato"
  i=0
  while [ -n "$(ls -A "$PUBLIC")" ] && [ "$i" -lt 60 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -s KILL -- "-$pid" 2> /dev/null
  wait "$pid"
  OUT="$(cat "$WORK/out")"
  expect_public_empty
}

test_marker_removed_on_int() { interrupted_by INT; }
test_marker_removed_on_term() { interrupted_by TERM; }
test_marker_removed_on_hup() { interrupted_by HUP; }

# Una connessione SSH che cade arriva al module come SIGPIPE alla prima riga che
# prova a scrivere: qui lo simula head, che chiude dopo la prima.
test_marker_removed_when_output_closes() {
  fresh_public
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  inizio="$(date +%s)"
  OUT="$(spawn --timeout 10 2>&1 | head -n 1)"
  durata=$(($(date +%s) - inizio))
  expect_public_empty
  [ "$durata" -lt 8 ] || fail "il module ha continuato fino al timeout dopo la chiusura dell'output (${durata}s)"
}

# --- verdetti di default ----------------------------------------------------

test_match_after_404() {
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"', {"status": 200, "body": "R1\n"}], '"$HEALTHY"'}'
  smoke
  expect_rc 0
  expect_out 'release in linea: R1'
  expect_out 'release-smoke-test: online'
}

test_mismatch_until_timeout() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out 'dopo 2s il marcatore non è quello della release R1 (verdetto: mismatch, HTTP 200)'
  expect_out 'release-smoke-test: timeout'
  expect_not_requested /up
  expect_not_requested /
}

test_mismatch_then_match() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R0"}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_out 'marcatore: mismatch'
}

test_empty_body_is_no_response() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "  \n"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 200)'
}

test_dropped_connection_waits() {
  serve '{"'"$MARKER"'": [{"drop": true}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_out 'marcatore: no-response (HTTP 000)'
}

test_timeout_reports_last_code() {
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 404)'
}

test_timeout_without_answer() {
  serve '{"'"$MARKER"'": [{"drop": true}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 000)'
}

test_cloudflare_challenge_stops() {
  serve '{"'"$MARKER"'": [{"status": 403, "body": "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script src=\"/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1\"></script></body></html>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'una protezione anti-bot risponde al posto del marcatore'
  expect_out "prova smoke-from 'server'"
  expect_out 'release-smoke-test: challenged'
  expect_not_requested /up
}

# una firma per protezione: ognuna basta da sola, su 403 o su 503
test_challenge_signatures() {
  for page in \
    '<html><title>Attention Required! | Cloudflare</title></html>' \
    '<html><title>Sucuri WebSite Firewall - Access Denied</title></html>' \
    '<html><script src="/_Incapsula_Resource?SWJIYLWA=1"></script></html>' \
    '<html><body>Access denied by Imunify360 bot-protection</body></html>' \
    '<html><title>DDoS-Guard</title></html>'; do
    for status in 403 503; do
      body="$(printf '%s' "$page" | sed 's/"/\\"/g')"
      serve '{"'"$MARKER"'": [{"status": '"$status"', "body": "'"$body"'"}], '"$HEALTHY"'}'
      smoke --timeout 60
      expect_rc 1
      expect_out 'release-smoke-test: challenged'
    done
  done
}

# un 403 senza firme di challenge non è definitivo: può essere un permesso
# sbagliato che la Release nuova corregge
test_forbidden_without_challenge_waits() {
  serve '{"'"$MARKER"'": [{"status": 403, "body": "<html><title>403 Forbidden</title></html>"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: mismatch, HTTP 403)'
  expect_out 'release-smoke-test: timeout'
}

# la firma conta solo su 403 e 503: con 200 una pagina che la cita non è una challenge
test_challenge_signature_on_200_is_not_challenged() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "Just a moment..."}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_no_out 'release-smoke-test: challenged'
  expect_out 'release-smoke-test: timeout'
}

test_html_page_with_200_stops() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "<!DOCTYPE html>\n<html><head><title>Default vhost</title></head></html>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'risponde una pagina HTML invece del marcatore: questo vhost non serve la Release'
  expect_out 'release-smoke-test: html-page'
  expect_not_requested /up
}

# senza doctype e con il tag <html> che va a capo prima degli attributi
test_html_page_without_doctype_stops() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "<html\n  lang=\"it\"><body>Index of /</body></html>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'release-smoke-test: html-page'
}

# un frammento HTML senza <html>, come la pagina di default di certi pannelli
test_html_fragment_stops() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "<body><h1>Sito in costruzione</h1></body>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'release-smoke-test: html-page'
}

# la pagina 404 della Release precedente è attesa, mai html-page
test_html_404_waits() {
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"', {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_no_out 'html-page'
  expect_out 'marcatore: no-response (HTTP 404)'
}

# --- health path e home -----------------------------------------------------

test_health_path_failure() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/up": [{"status": 500}], "/": [{"status": 200}]}'
  smoke
  expect_rc 1
  expect_out 'smoke test fallito: /up=500'
  expect_out '/up → 500 · / → 200'
  expect_out 'release-smoke-test: unhealthy'
}

test_home_failure() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 503}]}'
  smoke
  expect_rc 1
  expect_out 'smoke test fallito: /=503'
}

test_custom_health_path() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/login": [{"status": 200}], "/": [{"status": 200}]}'
  smoke --health-path /login
  expect_rc 0
  expect_requested /login
  expect_not_requested /up
}

test_follow_redirects_on_home() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  smoke --redirects follow
  expect_rc 1
  expect_out '/ → 500'
}

test_no_redirects_on_home() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  smoke --redirects none
  expect_rc 0
  expect_out '/ → 302'
  expect_not_requested /login
}

# --- redirect del marcatore -------------------------------------------------

# Il dominio forza HTTPS: http:// risponde 301 verso lo stesso host e lo stesso
# percorso in https://, che serve la Release.
FORCED_HTTPS='{"status": 301, "body": "Moved Permanently", "headers": {"Location": "https://127.0.0.1:{port}'"$MARKER"'"}}'

test_server_switches_to_https_when_forced() {
  serve '{"'"$MARKER"'": ['"$FORCED_HTTPS"'], "https '"$MARKER"'": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --redirects none
  expect_rc 0
  expect_out 'release-smoke-test: online'
  expect_requested "https $MARKER"
  expect_requested 'https /up'
  expect_requested 'https /'
  expect_out "conviene APP_URL=https://127.0.0.1:$PORT nel .env"
  expect_out "release-smoke-test-url: https://127.0.0.1:$PORT"
}

test_https_switch_note_as_github_annotation() {
  serve '{"'"$MARKER"'": ['"$FORCED_HTTPS"'], "https '"$MARKER"'": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --redirects none --github
  expect_rc 0
  expect_out '::notice::http:// redirige su https://'
}

test_no_url_line_without_switch() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --redirects none
  expect_rc 0
  expect_no_out 'release-smoke-test-url:'
}

test_server_redirect_to_other_host_stops() {
  serve '{"'"$MARKER"'": [{"status": 301, "body": "Moved", "headers": {"Location": "https://altro.example/release.txt"}}], '"$HEALTHY"'}'
  smoke --redirects none --timeout 60
  expect_rc 1
  expect_out 'HTTP 301'
  expect_out 'https://altro.example/release.txt'
  expect_out 'release-smoke-test: redirect'
  expect_no_out 'release-smoke-test-url:'
}

test_server_redirect_to_other_path_stops() {
  serve '{"'"$MARKER"'": [{"status": 302, "body": "Found", "headers": {"Location": "https://127.0.0.1:{port}/login"}}], '"$HEALTHY"'}'
  smoke --redirects none --timeout 60
  expect_rc 1
  expect_out 'HTTP 302'
  expect_out 'release-smoke-test: redirect'
  expect_not_requested 'https /login'
}

test_server_redirect_after_https_switch_stops() {
  serve '{"'"$MARKER"'": ['"$FORCED_HTTPS"'], "https '"$MARKER"'": [{"status": 301, "headers": {"Location": "https://www.example/release.txt"}}], '"$HEALTHY"'}'
  smoke --redirects none --timeout 60
  expect_rc 1
  expect_out "release-smoke-test-url: https://127.0.0.1:$PORT"
  expect_out 'release-smoke-test: redirect'
}

test_runner_redirect_to_other_host_waits_as_before() {
  serve '{"'"$MARKER"'": [{"status": 301, "body": "Moved", "headers": {"Location": "https://altro.example/release.txt"}}], '"$HEALTHY"'}'
  smoke --redirects follow
  expect_rc 1
  expect_out '(verdetto: mismatch, HTTP 301)'
  expect_out 'release-smoke-test: timeout'
  expect_no_out 'release-smoke-test: redirect'
}

test_runner_switches_to_https_when_forced() {
  serve '{"'"$MARKER"'": ['"$FORCED_HTTPS"'], "https '"$MARKER"'": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --redirects follow
  expect_rc 0
  expect_out 'release-smoke-test: online'
  expect_out "conviene APP_URL=https://127.0.0.1:$PORT nel .env"
  expect_out "release-smoke-test-url: https://127.0.0.1:$PORT"
  expect_requested 'https /up'
  expect_requested 'https /'
}

# --- funzioni per chi usa il module da fuori (setup-releases) ----------------

# Chiama una funzione del module come fa setup-releases: il module concatenato
# prima di uno script con set -eu, tutto su stdin.
from_script() {
  fn="$1"
  shift
  OUT="$({ cat "$MODULE"; printf 'set -eu\n%s "$@"\n' "$fn"; } |
    CURL_CA_BUNDLE="$WORK/cert.pem" "$TEST_SHELL" -s -- "$@" 2>&1)"
  RC=$?
}

expect_exact_out() {
  [ "$OUT" = "$1" ] || fail "output '$OUT', atteso '$1'"
}

test_https_switches_when_forced() {
  serve '{"'"$MARKER"'": ['"$FORCED_HTTPS"']}'
  from_script release_smoke_https "$URL/"
  expect_rc 0
  expect_exact_out "https://127.0.0.1:$PORT"
}

test_https_keeps_url_on_redirect_to_other_host() {
  serve '{"'"$MARKER"'": [{"status": 301, "headers": {"Location": "https://altro.example'"$MARKER"'"}}]}'
  from_script release_smoke_https "$URL"
  expect_rc 0
  expect_exact_out "$URL"
}

test_https_keeps_url_without_redirect() {
  serve '{}'
  from_script release_smoke_https "$URL"
  expect_rc 0
  expect_exact_out "$URL"
}

test_codice_without_redirects() {
  serve '{"/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  from_script release_smoke_codice "$URL/" none
  expect_rc 0
  expect_exact_out 302
  expect_not_requested /login
}

test_codice_following_redirects() {
  serve '{"/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  from_script release_smoke_codice "$URL/" follow
  expect_rc 0
  expect_exact_out 500
}

test_codice_without_answer() {
  serve '{"/": [{"drop": true}]}'
  from_script release_smoke_codice "$URL/" none
  expect_rc 0
  case "$OUT" in *000) ;; *) fail "output '$OUT', atteso che finisca con 000" ;; esac
}

test_risposta_body_then_code_and_redirect() {
  serve '{"/a": [{"status": 200, "body": "ciao"}], "/b": [{"status": 301, "headers": {"Location": "https://altro.example/b"}}]}'
  from_script release_smoke_risposta "$URL/a"
  expect_rc 0
  expect_exact_out "ciao
200 "
  from_script release_smoke_risposta "$URL/b"
  expect_exact_out "
301 https://altro.example/b"
}

# il caso che le sonde del document root di setup-releases devono distinguere
test_risposta_empty_body() {
  serve '{"/a": [{"status": 200, "body": ""}]}'
  from_script release_smoke_risposta "$URL/a"
  expect_rc 0
  expect_exact_out "
200 "
}

# setup-releases chiama lo smoke test da uno script con set -eu e decide lui
# cosa fare dopo: un fallimento non deve chiudere lo script chiamante.
smoke_from_strict_script() {
  OUT="$({ cat "$MODULE"; printf '%s\n' 'set -eu' \
    'if release_smoke_test "$@"; then echo "chiamante: verde"; else echo "chiamante: rosso $?"; fi'; } |
    CURL_CA_BUNDLE="$WORK/cert.pem" "$TEST_SHELL" -s -- --url "$URL" --release R1 \
      --marker-dir "$PUBLIC" --timeout 2 --interval 1 --redirects none 2>&1)"
  RC=$?
}

test_smoke_from_strict_script_online() {
  fresh_public
  serve '{'"$PHP_MARKER"', '"$HEALTHY"'}'
  smoke_from_strict_script
  expect_rc 0
  expect_out 'release-smoke-test: online'
  expect_out 'chiamante: verde'
  expect_public_empty
}

test_smoke_from_strict_script_failing() {
  fresh_public
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  smoke_from_strict_script
  expect_rc 0
  expect_out 'release-smoke-test: timeout'
  expect_out 'chiamante: rosso 1'
  expect_public_empty
}

test_salute_healthy() {
  from_script release_smoke_salute /up 200 302
  expect_rc 0
}

test_salute_health_path_not_200() {
  from_script release_smoke_salute /up 302 200
  expect_rc 1
  expect_exact_out '/up=302'
}

test_salute_both_failing() {
  from_script release_smoke_salute /up 404 500
  expect_rc 1
  expect_exact_out '/up=404 /=500'
}

test_salute_with_decisions() {
  from_script release_smoke_salute /up 500 200 "$DECISIONS"
  expect_rc 1
  expect_exact_out 'salute=500'
}

# --- decisions-script --------------------------------------------------------

test_decisions_never_receive_404() {
  rm -f "$DECISIONS_LOG"
  serve '{"'"$MARKER"'": ['"$NOT_FOUND"', {"drop": true}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10 --decisions "$DECISIONS"
  expect_rc 0
  expect_out 'release-smoke-test: online'
  grep -q 'Not Found' "$DECISIONS_LOG" && fail "il decisions-script ha ricevuto il 404"
  grep -qxF 'smoke-marker R1 <R1>' "$DECISIONS_LOG" || fail "smoke-marker non ha ricevuto release e corpo"
  grep -qxF 'smoke-health 200 200' "$DECISIONS_LOG" || fail "smoke-health non ha ricevuto i due codici"
}

test_decisions_mismatch() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: mismatch, HTTP 200)'
}

test_decisions_no_response() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": ""}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 200)'
}

test_decisions_unknown_verdict_waits() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "boh"}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10 --decisions "$DECISIONS"
  expect_rc 0
  expect_out 'marcatore: boh'
}

test_decisions_unknown_verdict_times_out() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "boh"}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: boh, HTTP 200)'
}

test_decisions_html_page_stops() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "<html>vhost</html>"}], '"$HEALTHY"'}'
  smoke --timeout 60 --decisions "$DECISIONS"
  expect_rc 1
  expect_out 'risponde una pagina HTML invece del marcatore'
  expect_out 'release-smoke-test: html-page'
}

test_decisions_challenged_stops() {
  serve '{"'"$MARKER"'": [{"status": 403, "body": "js challenge"}], '"$HEALTHY"'}'
  smoke --timeout 60 --decisions "$DECISIONS"
  expect_rc 1
  expect_out 'una protezione anti-bot risponde al posto del marcatore'
  expect_out 'release-smoke-test: challenged'
}

# il decisions-script ha la precedenza: dove il default direbbe html-page o
# challenged, decide lui
test_decisions_override_default() {
  cat > "$WORK/sempre-match.sh" <<'EOF'
#!/bin/sh
[ "$1" = smoke-marker ] && echo match
exit 0
EOF
  chmod +x "$WORK/sempre-match.sh"
  serve '{"'"$MARKER"'": [{"status": 200, "body": "<!DOCTYPE html><html>R1</html>"}], '"$HEALTHY"'}'
  smoke --decisions "$WORK/sempre-match.sh"
  expect_rc 0
  expect_out 'release-smoke-test: online'
  serve '{"'"$MARKER"'": [{"status": 403, "body": "<title>Just a moment...</title>"}], '"$HEALTHY"'}'
  smoke --decisions "$WORK/sempre-match.sh"
  expect_rc 0
  expect_out 'release-smoke-test: online'
}

test_decisions_health_failure() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], "/up": [{"status": 500}], "/": [{"status": 200}]}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out 'smoke test fallito: salute=500'
}

# --- interface ----------------------------------------------------------------

test_github_annotations() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke --github
  expect_rc 1
  expect_out '::error::dopo 2s il marcatore'
}

test_plain_errors() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke
  expect_no_out '::error::'
  expect_out 'errore: dopo 2s'
}

test_rejects_unknown_redirect_mode() {
  serve '{}'
  smoke --redirects sometimes
  expect_rc 2
  expect_out 'release-smoke-test: usage'
}

test_rejects_missing_release() {
  serve '{}'
  OUT="$("$TEST_SHELL" "$MODULE" --url "$URL" 2>&1)"
  RC=$?
  expect_rc 2
}

test_rejects_missing_decisions_script() {
  serve '{}'
  smoke --decisions "$WORK/assente.sh"
  expect_rc 2
}

test_rejects_non_executable_decisions_script() {
  serve '{}'
  printf '#!/bin/sh\necho match\n' > "$WORK/non-eseguibile.sh"
  smoke --decisions "$WORK/non-eseguibile.sh"
  expect_rc 2
  expect_out 'non è eseguibile'
}

test_callable_as_function_from_stdin() {
  serve '{"'"$MARKER"'": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  OUT="$({ cat "$MODULE"; printf '%s\n' 'release_smoke_test "$@"; echo "dopo: $?"'; } |
    "$TEST_SHELL" -s -- --url "$URL" --release R1 --interval 1 2>&1)"
  RC=$?
  expect_rc 0
  expect_out 'release-smoke-test: online'
  expect_out 'dopo: 0'
}

# --- esecuzione ---------------------------------------------------------------

TESTS="$(grep -oE '^test_[a-z0-9_]+\(\)' "$0" | tr -d '()')"
for t in $TESTS; do
  CURRENT_FAILED=''
  echo "• $t"
  "$t"
  if [ -n "$CURRENT_FAILED" ]; then
    FAILED=$((FAILED + 1))
    printf '%s\n' "$OUT" | sed 's/^/      | /'
  else
    PASSED=$((PASSED + 1))
  fi
done
stop_server

echo
echo "superati: $PASSED · falliti: $FAILED"
[ "$FAILED" -eq 0 ]
