#!/bin/sh
# Suite delle fasi legacy e cleanup di scripts/setup-releases.sh.
#
# Lancia lo script come in produzione, concatenato a un module e inviato su
# stdin a 'sh -s', contro un sito piatto finto in una directory temporanea. Il
# module è uno stub che dà il sito sempre sano e lo smoke test sempre verde:
# lo smoke test ha la sua suite, qui interessa cosa succede ai file. Un tar
# finto, primo nel PATH, registra gli argomenti e lancia il tar vero.
#
# Uso: scripts/tests/setup-releases.test.sh
# Ambiente:
#   TEST_SHELL  la shell con cui lanciare lo script (default: dash se c'è,
#               altrimenti sh)
#
# Dipendenze: GNU tar.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../setup-releases.sh"
if [ -z "${TEST_SHELL:-}" ]; then
  if command -v dash > /dev/null 2>&1; then TEST_SHELL='dash'; else TEST_SHELL='sh'; fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

# Lo stub del module: le stesse funzioni che setup-releases.sh chiama.
STUB="$WORK/stub-module.sh"
cat > "$STUB" <<'EOF'
release_smoke_test() { echo "release-smoke-test: online"; }
release_smoke_https() { printf '%s' "${1%/}"; }
release_smoke_codice() { echo 200; }
release_smoke_salute() { return 0; }
EOF

TAR_LOG="$WORK/tar.log"
REAL_TAR="$(command -v tar)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tar" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$TAR_LOG'
exec '$REAL_TAR' "\$@"
EOF
chmod +x "$WORK/bin/tar"
PATH="$WORK/bin:$PATH"
export PATH

# Un checkpoint ogni record da 10 KiB invece che ogni ~1 GB: i file del sito
# finto bastano a far stampare l'avanzamento.
SETUP_RELEASES_CHECKPOINT=1
export SETUP_RELEASES_CHECKPOINT

PASSED=0
FAILED=0
CURRENT_FAILED=''
OUT=""
RC=""

fail() {
  CURRENT_FAILED=1
  echo "    ✗ $*"
}

# Un sito piatto già passato da bridge e shared: current -> BASE, .env e
# storage spostati in shared/ con un symlink di ritorno.
BASE=''
fresh_site() {
  BASE="$WORK/sito"
  rm -rf "$BASE"
  mkdir -p "$BASE/public" "$BASE/vendor" "$BASE/app" "$BASE/bootstrap/cache" \
    "$BASE/releases" "$BASE/tmp" "$BASE/shared/storage/app/public" "$BASE/shared/storage/logs"
  echo '<?php // artisan' > "$BASE/artisan"
  echo '<?php // index' > "$BASE/public/index.php"
  echo '<?php // autoload' > "$BASE/vendor/autoload.php"
  head -c 60000 /dev/urandom > "$BASE/app/codice.bin"
  head -c 200000 /dev/urandom > "$BASE/shared/storage/logs/laravel.log"
  echo 'foto' > "$BASE/shared/storage/app/public/foto.jpg"
  echo 'nome con spazi' > "$BASE/nome con spazi.txt"
  printf 'APP_URL=http://sito.test\nAPP_KEY=base64:x\n' > "$BASE/shared/.env"
  ln -s shared/.env "$BASE/.env"
  ln -s shared/storage "$BASE/storage"
  ln -s ../storage/app/public "$BASE/public/storage"
  ln -s "$BASE" "$BASE/current"
  : > "$TAR_LOG"
}

# Lancia una fase come la lancia il README, con lo stub al posto del module.
fase() {
  OUT="$(cat "$STUB" "$SCRIPT" | "$TEST_SHELL" -s -- "$1" --from-existing "$BASE" --no-color --timeout 1 2>&1)"
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

expect_file() {
  [ -e "$1" ] || [ -L "$1" ] || fail "manca $1"
}

expect_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "non doveva esistere: $1"
}

# Nessuna invocazione di tar ha letto l'archivio (né -x né -t).
expect_archive_not_read() {
  if grep -E -- '(^| )-[a-zA-Z]*[xt][a-zA-Z]* .*000-legacy\.tar\.gz|000-legacy\.tar\.gz.* -[a-zA-Z]*[xt]' "$TAR_LOG" > /dev/null; then
    fail "tar ha letto l'archivio: $(cat "$TAR_LOG")"
  fi
}

# --- legacy --------------------------------------------------------------------

test_legacy_builds_release_with_code_only() {
  fresh_site
  fase legacy
  expect_rc 0
  L="$BASE/releases/000-legacy"
  expect_file "$L/artisan"
  expect_file "$L/app/codice.bin"
  expect_file "$L/nome con spazi.txt"
  cmp -s "$BASE/app/codice.bin" "$L/app/codice.bin" || fail "app/codice.bin diverso nella Release"
  [ -L "$L/storage" ] || fail "storage nella Release non è un symlink"
  [ -L "$L/.env" ] || fail ".env nella Release non è un symlink"
  [ -L "$L/public/storage" ] || fail "public/storage nella Release non è un symlink"
  [ "$(readlink -f "$L/storage")" = "$(readlink -f "$BASE/shared/storage")" ] || fail "storage non punta a shared/storage"
  [ "$(readlink -f "$BASE/current")" = "$(readlink -f "$L")" ] || fail "current non punta alla Release"
  for p in releases shared tmp current; do
    expect_absent "$L/$p"
  done
}

test_legacy_archive_is_full_snapshot() {
  fresh_site
  fase legacy
  expect_rc 0
  voci="$("$REAL_TAR" -tzf "$BASE/shared/000-legacy.tar.gz")"
  for v in ./.env ./storage/logs/laravel.log ./app/codice.bin; do
    printf '%s\n' "$voci" | grep -qxF "$v" || fail "nell'archivio manca $v"
  done
}

test_legacy_copies_release_without_reading_archive() {
  fresh_site
  fase legacy
  expect_rc 0
  expect_archive_not_read
}

test_legacy_prints_progress_with_totals() {
  fresh_site
  fase legacy
  expect_rc 0
  # archivio: codice e storage; copia: solo codice
  printf '%s\n' "$OUT" | grep -Eq '^ +[0-9]+ / [0-9]+ MB \([0-9]+%\)$' || fail "nessuna riga di avanzamento X / Y MB (Z%)"
  n1="$(printf '%s\n' "$OUT" | sed -n '/^1\. /,/^2\. /p' | grep -c ' MB (')"
  n2="$(printf '%s\n' "$OUT" | sed -n '/^2\. /,/^3\. /p' | grep -c ' MB (')"
  [ "$n1" -gt 0 ] || fail "nessun avanzamento al passo 1"
  [ "$n2" -gt 0 ] || fail "nessun avanzamento al passo 2"
}

test_legacy_writes_entry_list_next_to_archive() {
  fresh_site
  fase legacy
  expect_rc 0
  ELENCO="$BASE/shared/000-legacy.voci"
  expect_file "$ELENCO"
  [ "$(stat -c '%a' "$ELENCO")" = 600 ] || fail "permessi dell'elenco $(stat -c '%a' "$ELENCO"), attesi 600"
  for v in .env storage artisan app public vendor bootstrap 'nome con spazi.txt'; do
    grep -qxF "$v" "$ELENCO" || fail "nell'elenco manca '$v'"
  done
  for v in releases shared tmp current; do
    ! grep -qxF "$v" "$ELENCO" || fail "nell'elenco non doveva esserci '$v'"
  done
}

# --- cleanup -------------------------------------------------------------------

test_cleanup_uses_entry_list_without_reading_archive() {
  fresh_site
  fase legacy
  expect_rc 0
  : > "$TAR_LOG"
  echo nuovo > "$BASE/comparso-dopo.txt"
  fase cleanup
  expect_rc 0
  [ ! -s "$TAR_LOG" ] || fail "cleanup ha lanciato tar: $(cat "$TAR_LOG")"
  for v in artisan app public vendor bootstrap 'nome con spazi.txt' .env storage; do
    expect_absent "$BASE/$v"
  done
  expect_file "$BASE/comparso-dopo.txt"
  expect_out "comparso-dopo.txt  <- non era nell'archivio: lasciato"
  expect_file "$BASE/shared/000-legacy.tar.gz"
}

# Un archivio creato da una versione precedente non ha l'elenco accanto: si
# torna a leggere l'archivio, mostrando l'avanzamento.
test_cleanup_without_entry_list_reads_archive_with_progress() {
  fresh_site
  fase legacy
  expect_rc 0
  rm "$BASE/shared/000-legacy.voci"
  : > "$TAR_LOG"
  fase cleanup
  expect_rc 0
  grep -q -- '-tzf' "$TAR_LOG" || fail "cleanup non ha letto l'archivio"
  printf '%s\n' "$OUT" | grep -Eq '^ +[0-9]+ MB letti$' || fail "nessuna riga di avanzamento in lettura"
  for v in artisan app public vendor 'nome con spazi.txt'; do
    expect_absent "$BASE/$v"
  done
}

# Un archivio rifatto a mano dopo legacy è più nuovo dell'elenco: l'elenco
# descrive un altro archivio, e si torna a leggere quello presente.
test_cleanup_ignores_entry_list_older_than_archive() {
  fresh_site
  fase legacy
  expect_rc 0
  touch -d '2000-01-01' "$BASE/shared/000-legacy.voci"
  : > "$TAR_LOG"
  fase cleanup
  expect_rc 0
  grep -q -- '-tzf' "$TAR_LOG" || fail "cleanup ha usato un elenco più vecchio dell'archivio"
}

test_cleanup_refuses_when_entry_missing_from_release() {
  fresh_site
  fase legacy
  expect_rc 0
  rm -rf "$BASE/releases/000-legacy/app"
  fase cleanup
  expect_rc 1
  expect_out "'app' è nell'archivio ma non in"
  expect_file "$BASE/artisan"
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

echo
echo "superati: $PASSED · falliti: $FAILED"
[ "$FAILED" -eq 0 ]
