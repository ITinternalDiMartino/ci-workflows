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
# Dipendenze: python3, curl.
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
  python3 -I "$SERVER" "$WORK/routes.json" "$WORK/port" "$WORK/requests" &
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
  URL="http://127.0.0.1:$(cat "$WORK/port")"
}

# Lancia il module contro il server, con un'attesa breve fra un tentativo e
# l'altro. Gli argomenti si aggiungono (e possono sostituire) quelli di default.
smoke() {
  OUT="$("$TEST_SHELL" "$MODULE" --url "$URL" --release R1 --health-path /up \
    --timeout 2 --interval 1 "$@" 2>&1)"
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

# la pagina 404 di Laravel della Release precedente, servita durante l'attesa
NOT_FOUND='{"status": 404, "body": "<!DOCTYPE html><html><title>Not Found</title></html>"}'
HEALTHY='"/up": [{"status": 200, "body": "ok"}], "/": [{"status": 200, "body": "home"}]'

# --- verdetti di default ----------------------------------------------------

test_match_after_404() {
  serve '{"/release.txt": ['"$NOT_FOUND"', {"status": 200, "body": "R1\n"}], '"$HEALTHY"'}'
  smoke
  expect_rc 0
  expect_out 'release in linea: R1'
  expect_out 'release-smoke-test: online'
}

test_mismatch_until_timeout() {
  serve '{"/release.txt": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out 'dopo 2s il marcatore non è quello della release R1 (verdetto: mismatch, HTTP 200)'
  expect_out 'release-smoke-test: timeout'
  expect_not_requested /up
  expect_not_requested /
}

test_mismatch_then_match() {
  serve '{"/release.txt": [{"status": 200, "body": "R0"}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_out 'marcatore: mismatch'
}

test_empty_body_is_no_response() {
  serve '{"/release.txt": [{"status": 200, "body": "  \n"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 200)'
}

test_dropped_connection_waits() {
  serve '{"/release.txt": [{"drop": true}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_out 'marcatore: no-response (HTTP 000)'
}

test_timeout_reports_last_code() {
  serve '{"/release.txt": ['"$NOT_FOUND"'], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 404)'
}

test_timeout_without_answer() {
  serve '{"/release.txt": [{"drop": true}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 000)'
}

test_cloudflare_challenge_stops() {
  serve '{"/release.txt": [{"status": 403, "body": "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><script src=\"/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1\"></script></body></html>"}], '"$HEALTHY"'}'
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
      serve '{"/release.txt": [{"status": '"$status"', "body": "'"$body"'"}], '"$HEALTHY"'}'
      smoke --timeout 60
      expect_rc 1
      expect_out 'release-smoke-test: challenged'
    done
  done
}

# un 403 senza firme di challenge non è definitivo: può essere un permesso
# sbagliato che la Release nuova corregge
test_forbidden_without_challenge_waits() {
  serve '{"/release.txt": [{"status": 403, "body": "<html><title>403 Forbidden</title></html>"}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_out '(verdetto: mismatch, HTTP 403)'
  expect_out 'release-smoke-test: timeout'
}

# la firma conta solo su 403 e 503: con 200 una pagina che la cita non è una challenge
test_challenge_signature_on_200_is_not_challenged() {
  serve '{"/release.txt": [{"status": 200, "body": "Just a moment..."}], '"$HEALTHY"'}'
  smoke
  expect_rc 1
  expect_no_out 'release-smoke-test: challenged'
  expect_out 'release-smoke-test: timeout'
}

test_html_page_with_200_stops() {
  serve '{"/release.txt": [{"status": 200, "body": "<!DOCTYPE html>\n<html><head><title>Default vhost</title></head></html>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'risponde una pagina HTML invece del marcatore: questo vhost non serve la Release'
  expect_out 'release-smoke-test: html-page'
  expect_not_requested /up
}

# senza doctype e con il tag <html> che va a capo prima degli attributi
test_html_page_without_doctype_stops() {
  serve '{"/release.txt": [{"status": 200, "body": "<html\n  lang=\"it\"><body>Index of /</body></html>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'release-smoke-test: html-page'
}

# un frammento HTML senza <html>, come la pagina di default di certi pannelli
test_html_fragment_stops() {
  serve '{"/release.txt": [{"status": 200, "body": "<body><h1>Sito in costruzione</h1></body>"}], '"$HEALTHY"'}'
  smoke --timeout 60
  expect_rc 1
  expect_out 'release-smoke-test: html-page'
}

# la pagina 404 della Release precedente è attesa, mai html-page
test_html_404_waits() {
  serve '{"/release.txt": ['"$NOT_FOUND"', {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10
  expect_rc 0
  expect_no_out 'html-page'
  expect_out 'marcatore: no-response (HTTP 404)'
}

# --- health path e home -----------------------------------------------------

test_health_path_failure() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/up": [{"status": 500}], "/": [{"status": 200}]}'
  smoke
  expect_rc 1
  expect_out 'smoke test fallito: /up=500'
  expect_out '/up → 500 · / → 200'
  expect_out 'release-smoke-test: unhealthy'
}

test_home_failure() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 503}]}'
  smoke
  expect_rc 1
  expect_out 'smoke test fallito: /=503'
}

test_custom_health_path() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/login": [{"status": 200}], "/": [{"status": 200}]}'
  smoke --health-path /login
  expect_rc 0
  expect_requested /login
  expect_not_requested /up
}

test_follow_redirects_on_home() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  smoke --redirects follow
  expect_rc 1
  expect_out '/ → 500'
}

test_no_redirects_on_home() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/up": [{"status": 200}], "/": [{"status": 302, "headers": {"Location": "/login"}}], "/login": [{"status": 500}]}'
  smoke --redirects none
  expect_rc 0
  expect_out '/ → 302'
  expect_not_requested /login
}

# --- decisions-script --------------------------------------------------------

test_decisions_never_receive_404() {
  rm -f "$DECISIONS_LOG"
  serve '{"/release.txt": ['"$NOT_FOUND"', {"drop": true}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10 --decisions "$DECISIONS"
  expect_rc 0
  expect_out 'release-smoke-test: online'
  grep -q 'Not Found' "$DECISIONS_LOG" && fail "il decisions-script ha ricevuto il 404"
  grep -qxF 'smoke-marker R1 <R1>' "$DECISIONS_LOG" || fail "smoke-marker non ha ricevuto release e corpo"
  grep -qxF 'smoke-health 200 200' "$DECISIONS_LOG" || fail "smoke-health non ha ricevuto i due codici"
}

test_decisions_mismatch() {
  serve '{"/release.txt": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: mismatch, HTTP 200)'
}

test_decisions_no_response() {
  serve '{"/release.txt": [{"status": 200, "body": ""}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: no-response, HTTP 200)'
}

test_decisions_unknown_verdict_waits() {
  serve '{"/release.txt": [{"status": 200, "body": "boh"}, {"status": 200, "body": "R1"}], '"$HEALTHY"'}'
  smoke --timeout 10 --decisions "$DECISIONS"
  expect_rc 0
  expect_out 'marcatore: boh'
}

test_decisions_unknown_verdict_times_out() {
  serve '{"/release.txt": [{"status": 200, "body": "boh"}], '"$HEALTHY"'}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out '(verdetto: boh, HTTP 200)'
}

test_decisions_html_page_stops() {
  serve '{"/release.txt": [{"status": 200, "body": "<html>vhost</html>"}], '"$HEALTHY"'}'
  smoke --timeout 60 --decisions "$DECISIONS"
  expect_rc 1
  expect_out 'risponde una pagina HTML invece del marcatore'
  expect_out 'release-smoke-test: html-page'
}

test_decisions_challenged_stops() {
  serve '{"/release.txt": [{"status": 403, "body": "js challenge"}], '"$HEALTHY"'}'
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
  serve '{"/release.txt": [{"status": 200, "body": "<!DOCTYPE html><html>R1</html>"}], '"$HEALTHY"'}'
  smoke --decisions "$WORK/sempre-match.sh"
  expect_rc 0
  expect_out 'release-smoke-test: online'
  serve '{"/release.txt": [{"status": 403, "body": "<title>Just a moment...</title>"}], '"$HEALTHY"'}'
  smoke --decisions "$WORK/sempre-match.sh"
  expect_rc 0
  expect_out 'release-smoke-test: online'
}

test_decisions_health_failure() {
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], "/up": [{"status": 500}], "/": [{"status": 200}]}'
  smoke --decisions "$DECISIONS"
  expect_rc 1
  expect_out 'smoke test fallito: salute=500'
}

# --- interface ----------------------------------------------------------------

test_github_annotations() {
  serve '{"/release.txt": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
  smoke --github
  expect_rc 1
  expect_out '::error::dopo 2s il marcatore'
}

test_plain_errors() {
  serve '{"/release.txt": [{"status": 200, "body": "R0"}], '"$HEALTHY"'}'
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
  serve '{"/release.txt": [{"status": 200, "body": "R1"}], '"$HEALTHY"'}'
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
