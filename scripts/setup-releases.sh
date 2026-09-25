#!/bin/sh
# setup-releases.sh - impianto e migrazione al layout a rotazione di
# laravel-projects-deploy.yml su un dominio cPanel.
#
# Si esegue dal proprio computer, senza lasciare niente sul server:
#
#   ssh utente@host 'sh -s' -- <fase> <modalità> <BASE> [opzioni] < scripts/setup-releases.sh
#
# Siccome lo script arriva da stdin non può chiedere niente: ogni fase è un
# comando a sé e nessuna è interattiva. Le fasi, l'ordine del cutover e le
# trappole sono descritte in scripts/README.md.
#
# Modalità e fasi:
#   --from-existing   recon, bridge, shared, legacy, cleanup
#   --new             recon, shared
#
# Opzioni:
#   --url URL          URL del sito per le sonde (default: APP_URL del .env)
#   --php-bin PATH     PHP_BIN da verificare (default: il PHP del dominio)
#   --health-path P    percorso interrogato dalle sonde di legacy e cleanup (default: /)
#   --timeout N        secondi di attesa della sonda di release (default: 150)
#   --no-color         niente sequenze ANSI nell'output

set -eu
# Le directory create qui devono restare attraversabili dal web server, che su
# cPanel serve gli statici con un utente diverso dal proprietario.
umask 022

# ---------------------------------------------------------------------------
# output

R=''; G=''; Y=''; B=''; N=''
colori() {
  R="$(printf '\033[31m')"; G="$(printf '\033[32m')"; Y="$(printf '\033[33m')"
  B="$(printf '\033[1m')"; N="$(printf '\033[0m')"
}

say()     { printf '%s\n' "$*"; }
sezione() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
kv()      { printf '  %-30s %s\n' "$1" "$2"; }
nota()    { printf '  %s!!%s  %s\n' "$Y" "$N" "$*"; }
rosso()   { printf '%s%s%s\n' "$R" "$*" "$N"; }
muori()   { printf '%sERRORE: %s%s\n' "$R" "$*" "$N"; exit 1; }
# Una fase rilanciata su uno stato già fatto non è un errore: esce pulita.
gia_fatto() { printf '%sgià fatto:%s %s\n' "$G" "$N" "$*"; say "niente è stato modificato"; exit 0; }

usage() {
  sed -n '2,23p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  say "uso: ssh utente@host 'sh -s' -- <recon|bridge|shared|legacy|cleanup> <--new|--from-existing> <BASE> [opzioni] < setup-releases.sh"
}

# ---------------------------------------------------------------------------
# argomenti

FASE="${1:-}"
[ $# -gt 0 ] && shift
MODO=''; BASE=''; URL_OPT=''; PHP_OPT=''; HEALTH='/'; TIMEOUT=150; COLORE=1

valore() { [ -n "${2:-}" ] || muori "$1 vuole un valore"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --new) MODO=new ;;
    --from-existing) MODO=existing ;;
    --url) valore "$1" "${2:-}"; URL_OPT="$2"; shift ;;
    --php-bin) valore "$1" "${2:-}"; PHP_OPT="$2"; shift ;;
    --health-path) valore "$1" "${2:-}"; HEALTH="$2"; shift ;;
    --timeout) valore "$1" "${2:-}"; TIMEOUT="$2"; shift ;;
    --no-color) COLORE='' ;;
    -h | --help) usage; exit 0 ;;
    -*) muori "opzione sconosciuta: $1" ;;
    *)
      [ -z "$BASE" ] || muori "un solo percorso BASE, ricevuti '$BASE' e '$1'"
      BASE="$1"
      ;;
  esac
  shift
done
[ -n "$COLORE" ] && colori

case "$FASE" in
  recon | bridge | shared | legacy | cleanup) ;;
  '' | -h | --help) usage; exit 0 ;;
  *) muori "fase sconosciuta: '$FASE' (recon, bridge, shared, legacy, cleanup)" ;;
esac
[ -n "$MODO" ] || muori "manca la modalità: --new oppure --from-existing"
[ -n "$BASE" ] || muori "manca il percorso BASE, es. /home/utente/dominio.it"
case "$BASE" in /*) ;; *) muori "BASE deve essere un percorso assoluto: $BASE" ;; esac
case "$TIMEOUT" in '' | *[!0-9]*) muori "--timeout vuole un numero di secondi" ;; esac
case "$HEALTH" in /*) ;; *) HEALTH="/$HEALTH" ;; esac

# Su un dominio nuovo non c'è niente da servire: il ponte non ha oggetto, le
# sonde risponderebbero 404 comunque e non c'è nessun sito piatto da archiviare.
# Una fase che non fa niente insegnerebbe a ignorarla, quindi non esiste.
if [ "$MODO" = new ]; then
  case "$FASE" in
    bridge | legacy | cleanup)
      muori "--new non ha la fase $FASE: su un dominio nuovo ci sono solo recon e shared"
      ;;
  esac
fi

[ -d "$BASE" ] || muori "$BASE non esiste o non è una directory"
BASE_DATO="${BASE%/}"
# Il deploy confronta readlink -f di current con RELEASES_PATH/<release>: con un
# path non risolto (es. /home che è un symlink a /home2) quel confronto non
# tornerebbe mai. Tutto quello che viene stampato o confrontato è risolto.
BASE="$(cd "$BASE" && pwd -P)"
case "$BASE" in
  / | "$(cd "${HOME:-/}" 2>/dev/null && pwd -P)")
    [ "$FASE" = recon ] || muori "BASE è $BASE: questo script lavora sulla cartella di un dominio, non su / né sulla home"
    ;;
esac

RELS="$BASE/releases"
SH="$BASE/shared"
TMPD="$BASE/tmp"
CUR="$BASE/current"
LEGACY="$RELS/000-legacy"
ARCHIVIO="$SH/000-legacy.tar.gz"

# ---------------------------------------------------------------------------
# lettura dello stato

tipo_di() {
  if [ -L "$1" ]; then echo "symlink -> $(readlink "$1")"
  elif [ -d "$1" ]; then echo directory
  elif [ -f "$1" ]; then echo file
  elif [ -e "$1" ]; then echo altro
  else echo assente
  fi
}

tipo_current() {
  if [ -L "$CUR" ]; then echo symlink
  elif [ -d "$CUR" ]; then echo directory
  elif [ -e "$CUR" ]; then echo altro
  else echo assente
  fi
}

risolto() { readlink -f "$1" 2>/dev/null || true; }

# Legge una variabile da un .env con le stesse regole del deploy: niente CR,
# niente apici esterni. Non stampa mai il valore di chiavi segrete: chi chiama
# decide cosa mostrare.
env_var() {
  [ -f "$1" ] || return 0
  v="$(grep -m1 "^$2=" "$1" 2>/dev/null || true)"
  v="${v#*=}"
  v="$(printf '%s' "$v" | tr -d '\r')"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

env_file() {
  if [ -f "$SH/.env" ]; then echo "$SH/.env"
  elif [ -f "$BASE/.env" ]; then echo "$BASE/.env"
  fi
}

sito_url() {
  if [ -n "$URL_OPT" ]; then u="$URL_OPT"
  else
    f="$(env_file)"
    u="$( [ -n "$f" ] && env_var "$f" APP_URL || true)"
  fi
  printf '%s' "${u%/}"
}

# Segni che il sito piatto è ancora nella home. Bastano due indizi: artisan e il
# front controller sono in ogni progetto Laravel e in nessuna delle directory
# del layout nuovo.
originali_in_home() { [ -e "$BASE/artisan" ] || [ -e "$BASE/public/index.php" ]; }

STORAGE_ALBERO='app/public framework/cache framework/sessions framework/views logs'

# ---------------------------------------------------------------------------
# PHP. Mai `which php`: su cPanel restituisce /usr/local/bin/php, il PHP di
# sistema, mentre il dominio gira sulla versione scelta in MultiPHP.

# Stampa righe "versione<TAB>vhost<TAB>documentroot" per i vhost sotto BASE.
# uapi è disponibile all'utente cPanel e dice anche il document root reale.
# Il YAML ha liste annidate (phpversion_source), quindi i record si separano
# sull'indentazione del primo "-" dopo data:, e le chiavi si leggono solo a
# quella del primo campo.
uapi_vhost() {
  command -v uapi > /dev/null 2>&1 || return 0
  uapi LangPHP php_get_vhost_versions 2> /dev/null | awk -v base="$BASE" '
    function flush() {
      if (dr != "" && (dr == base || index(dr, base "/") == 1)) print ver "\t" vh "\t" dr
      dr = ""; ver = ""; vh = ""
    }
    /^ *data:/ { indata = 1; next }
    !indata { next }
    /^ *- *$/ {
      i = index($0, "-")
      if (ri == 0) ri = i
      if (i == ri) flush()
      next
    }
    {
      match($0, /^ */); ki_cur = RLENGTH
      if (ki == 0) ki = ki_cur
      if (ki_cur != ki) next
      k = $1; sub(/:$/, "", k)
      if (k == "documentroot") dr = $2
      else if (k == "version") ver = $2
      else if (k == "vhost") vh = $2
    }
    END { flush() }'
}

# Ripiego senza uapi: il blocco che MultiPHP scrive nell'.htaccess del
# document root ("AddHandler application/x-httpd-ea-php84").
htaccess_php() {
  for f in "$BASE/current/public/.htaccess" "$BASE/public/.htaccess" "$BASE/.htaccess"; do
    [ -f "$f" ] || continue
    v="$(grep -o 'ea-php[0-9][0-9]*' "$f" 2> /dev/null | head -n1 || true)"
    if [ -n "$v" ]; then
      printf '%s\t%s\n' "$v" "$f"
      return 0
    fi
  done
}

# Imposta DOM_PHP (es. ea-php84), DOM_FONTE, DOM_ROOT (se noto da uapi).
leggi_php_dominio() {
  DOM_PHP=''; DOM_FONTE=''; DOM_ROOT=''
  riga="$(uapi_vhost | head -n1)"
  if [ -n "$riga" ]; then
    DOM_PHP="$(printf '%s' "$riga" | cut -f1)"
    DOM_ROOT="$(printf '%s' "$riga" | cut -f3)"
    DOM_FONTE="uapi, vhost $(printf '%s' "$riga" | cut -f2)"
  fi
  if [ -z "$DOM_PHP" ]; then
    riga="$(htaccess_php || true)"
    if [ -n "$riga" ]; then
      DOM_PHP="$(printf '%s' "$riga" | cut -f1)"
      DOM_FONTE="handler in $(printf '%s' "$riga" | cut -f2)"
    fi
  fi
}

php_mm() { "$1" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2> /dev/null || true; }
php_full() { "$1" -r 'echo PHP_VERSION;' 2> /dev/null || echo '?'; }
# ea-php84 -> 8.4
ea_mm() { printf '%s' "$1" | sed -n 's/^ea-php\([0-9]\)\([0-9]*\)$/\1.\2/p'; }

# Imposta PHP_BIN: quello passato, altrimenti il binario ea-php del dominio.
leggi_php_bin() {
  PHP_BIN=''
  if [ -n "$PHP_OPT" ]; then PHP_BIN="$PHP_OPT"
  elif [ -n "$DOM_PHP" ] && [ -x "/opt/cpanel/$DOM_PHP/root/usr/bin/php" ]; then
    PHP_BIN="/opt/cpanel/$DOM_PHP/root/usr/bin/php"
  fi
}

# ---------------------------------------------------------------------------
# HTTP, dal server come fa il deploy con smoke-from: server

codice() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2> /dev/null || true; }
corpo() { curl -sS --max-time 10 "$1" 2> /dev/null || true; }
verde() { case "$1" in 2?? | 3??) return 0 ;; esac; return 1; }

richiedi_curl() { command -v curl > /dev/null 2>&1 || muori "sul server non c'è curl: le sonde ne hanno bisogno"; }

# Le sonde non devono restare servite: si cancellano all'uscita, anche se la
# connessione SSH cade a metà.
SONDE=''
rimuovi_sonde() { for s in $SONDE; do rm -f "$s"; done; SONDE=''; }
trap rimuovi_sonde EXIT
trap 'rimuovi_sonde; exit 130' INT TERM HUP

token() { printf '%s-%s-%s' "$1" "$(date +%s)" "$$"; }

# La sonda della release: un file PHP che esiste solo dentro $1. Finché la
# realpath cache di PHP (default 120s) risolve current nel posto vecchio, dove
# quel file non c'è, il token non torna. Senza questa attesa il sito
# risponderebbe verde dai file vecchi, che sono ancora intatti, anche con la
# release rotta. Poi la pagina vera deve rispondere 2xx o 3xx.
sonda_release() {
  tok="$(token rel)"
  f="$1/public/__probe-release.php"
  printf "<?php echo '%s';\n" "$tok" > "$f"
  SONDE="$SONDE $f"
  fine=$(($(date +%s) + TIMEOUT))
  while :; do
    visto="$(corpo "$URL/__probe-release.php" | tr -d '[:space:]')"
    if [ "$visto" = "$tok" ]; then
      say "  sonda: PHP risolve current in $1"
      break
    fi
    if [ "$(date +%s)" -ge "$fine" ]; then
      say "  sonda: dopo ${TIMEOUT}s PHP non serve ancora da $1 (risposta: $(printf '%.80s' "${visto:-vuota}"))"
      rimuovi_sonde
      return 1
    fi
    say "  sonda: non ancora, riprovo fra 10s"
    sleep 10
  done
  rimuovi_sonde
  c="$(codice "$URL$HEALTH")"
  say "  $URL$HEALTH -> ${c:-000}"
  verde "${c:-000}"
}

# ---------------------------------------------------------------------------
# swap atomico, identico a "Activate release" del deploy

punta_current() {
  ln -sfn "$1" "$CUR.new"
  if ! mv -Tf "$CUR.new" "$CUR" 2> /dev/null; then
    rm -f "$CUR.new"
    ln -sfn "$1" "$CUR"
    say "  attenzione: mv -T non supportato, swap non atomico"
  fi
  ora="$(risolto "$CUR")"
  say "  current -> $ora"
  [ "$ora" = "$1" ]
}

# ---------------------------------------------------------------------------
# controlli comuni alle fasi che modificano

# current come directory vera è la trappola di cPanel (vedi README): nessuna
# fase ci lavora sopra, e nessuna la cancella.
trappola_current() {
  [ "$(tipo_current)" = directory ] || return 0
  rosso "$CUR è una DIRECTORY VERA, non un symlink."
  rosso "cPanel la crea così quando il document root è impostato a /current/public alla creazione del dominio."
  rosso "Il deploy fallirebbe con 'lo swap non ha avuto effetto'. Va cancellata a mano, dopo averne guardato il contenuto:"
  rosso "  ls -la '$CUR'   e poi   rm -r '$CUR'"
  return 1
}

current_su_base() { [ "$(tipo_current)" = symlink ] && [ "$(risolto "$CUR")" = "$BASE" ]; }

# ---------------------------------------------------------------------------
# recon

MANCA=''
manca() { MANCA="${MANCA}  - $*
"; }

sugg_cron() {
  out="$1"
  for b in "$BASE" "$BASE_DATO"; do
    e="$(printf '%s' "$b" | sed 's/[][\.*^$#]/\\&/g')"
    # $b/current resta com'è, ogni altra occorrenza di $b passa per current
    out="$(printf '%s\n' "$out" | sed \
      -e "s#\\($e\\)/current#\\1@@C@@#g" \
      -e "s#\\($e\\)\\([/[:space:]\"';]\\|\$\\)#\\1/current\\2#g" \
      -e 's#@@C@@#/current#g')"
  done
  printf '%s' "$out"
}

recon() {
  if [ "$MODO" = new ]; then
    say "${B}modalità: --new${N} (impianto su un dominio nuovo: fasi recon e shared) · BASE $BASE"
  else
    say "${B}modalità: --from-existing${N} (migrazione di un sito già in linea: recon, bridge, shared, legacy, cleanup) · BASE $BASE"
  fi

  # Prima di tutto il resto: è il controllo che vale più di tutti gli altri.
  sezione current
  TC="$(tipo_current)"
  case "$TC" in
    directory)
      trappola_current || true
      say "  contenuto di current:"
      # shellcheck disable=SC2012 # output da leggere, non da elaborare
      ls -la "$CUR" | sed 's/^/    /'
      manca "current è una directory vera: cancellarla a mano (vedi sopra)"
      ;;
    symlink)
      kv "current" "symlink -> $(readlink "$CUR")"
      kv "risolve in" "$(risolto "$CUR")"
      [ -e "$CUR" ] || nota "il symlink è rotto: punta a qualcosa che non esiste"
      ;;
    altro) rosso "$CUR esiste ma non è né symlink né directory"; manca "current da sistemare a mano" ;;
    assente) kv "current" "assente" ;;
  esac

  [ "$BASE" = "$BASE_DATO" ] || nota "BASE passato come $BASE_DATO, risolto in $BASE: nelle vars va il path risolto, perché il deploy confronta readlink -f"
  case "$BASE" in
    / | "$(cd "${HOME:-/}" 2> /dev/null && pwd -P)") rosso "BASE è / o la home: nessuna fase che modifica accetterà di lavorarci" ;;
  esac

  sezione "forma della cartella"
  say "  voci in $BASE:"
  NOTI=' app bootstrap config database lang public resources routes storage vendor tests node_modules stubs artisan composer.json composer.lock package.json package-lock.json vite.config.js vite.config.ts webpack.mix.js tailwind.config.js postcss.config.js phpunit.xml .env .env.example .editorconfig .gitattributes .gitignore .htaccess .user.ini README.md CHANGELOG.md .git .github releases shared tmp current cgi-bin .well-known error_log '
  for p in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    n="${p##*/}"
    case "$NOTI" in
      *" $n "*) printf '    %-26s %s\n' "$n" "$(tipo_di "$p")" ;;
      *) printf '    %-26s %s  %s<- non riconosciuto%s\n' "$n" "$(tipo_di "$p")" "$Y" "$N" ;;
    esac
  done

  say "  symlink (profondità 3, esclusi releases, shared, tmp, vendor, node_modules):"
  find "$BASE" -maxdepth 3 \( -path "$RELS" -o -path "$SH" -o -path "$TMPD" -o -path "$BASE/vendor" -o -path "$BASE/node_modules" \) -prune \
    -o -type l -printf '    %p -> %l\n' 2> /dev/null || true

  kv ".env" "$(tipo_di "$BASE/.env")"
  kv "storage/" "$(tipo_di "$BASE/storage")"
  kv "public/storage" "$(tipo_di "$BASE/public/storage")"
  kv "spazio libero (df)" "$(df -Pk "$BASE" | awk 'NR==2 { printf "%.1f GB", $4 / 1048576 }')"

  sezione "layout a rotazione"
  kv "releases/" "$(tipo_di "$RELS")"
  if [ -d "$RELS" ]; then
    for r in "$RELS"/*; do [ -e "$r" ] && say "    $(basename "$r")  $(tipo_di "$r")"; done
  fi
  kv "shared/" "$(tipo_di "$SH")"
  kv "tmp/" "$(tipo_di "$TMPD")"
  kv "shared/.env" "$(tipo_di "$SH/.env")"
  if [ -f "$SH/.env" ]; then
    kv "  permessi" "$(stat -c '%a' "$SH/.env")"
    [ "$(stat -c '%a' "$SH/.env")" = 600 ] || nota "shared/.env non è 600: contiene credenziali"
    if [ -n "$(env_var "$SH/.env" APP_KEY)" ]; then kv "  APP_KEY" "valorizzata"; else kv "  APP_KEY" "VUOTA"; fi
    kv "  APP_URL" "$(env_var "$SH/.env" APP_URL)"
    kv "  APP_NAME" "$(env_var "$SH/.env" APP_NAME)"
  fi
  kv "shared/storage/" "$(tipo_di "$SH/storage")"
  if [ -d "$SH/storage" ]; then
    for d in $STORAGE_ALBERO; do
      if [ -d "$SH/storage/$d" ]; then kv "  $d" "c'è"; else kv "  $d" "MANCA"; fi
    done
    [ -w "$SH/storage" ] || nota "shared/storage non è scrivibile dall'utente"
  fi

  if [ "$MODO" = existing ]; then
    sezione "stato della migrazione"
    kv "shared/000-legacy.tar.gz" "$(tipo_di "$ARCHIVIO")"
    [ -f "$ARCHIVIO" ] && kv "  dimensione, permessi" "$(du -h "$ARCHIVIO" | cut -f1), $(stat -c '%a' "$ARCHIVIO")"
    kv "releases/000-legacy" "$(tipo_di "$LEGACY")"
    if [ -d "$LEGACY" ]; then
      kv "  .env" "$(tipo_di "$LEGACY/.env") (risolve in $(risolto "$LEGACY/.env"))"
      kv "  storage" "$(tipo_di "$LEGACY/storage") (risolve in $(risolto "$LEGACY/storage"))"
    fi
    if originali_in_home; then kv "file originali nella home" "sì"; else kv "file originali nella home" "no"; fi

    DEST="$(risolto "$CUR")"
    if [ "$TC" = assente ]; then PROSSIMA="bridge"
    elif [ "$TC" = directory ]; then PROSSIMA="cancellare a mano la directory current, poi bridge"
    elif [ "$DEST" = "$BASE" ] && [ ! -d "$SH" ]; then PROSSIMA="cambiare il document root in $BASE/current/public dal pannello, poi shared"
    elif [ "$DEST" = "$BASE" ] && [ -d "$LEGACY" ]; then PROSSIMA="legacy (interrotta al passo 5: si rilancia)"
    elif [ "$DEST" = "$BASE" ]; then PROSSIMA="legacy"
    elif [ "$DEST" = "$LEGACY" ] && originali_in_home; then PROSSIMA="cleanup"
    elif [ "$DEST" = "$LEGACY" ]; then PROSSIMA="spostare i cron, poi il primo deploy sullo stesso commit in produzione"
    else
      case "$DEST" in
        "$RELS"/*) PROSSIMA="nessuna: il layout a rotazione è attivo" ;;
        *) PROSSIMA="nessuna riconosciuta: current punta fuori da BASE e da releases/" ;;
      esac
    fi
    kv "fase successiva" "$PROSSIMA"

    case "$DEST" in
      "$RELS"/*) originali_in_home && manca "i file originali sono ancora nella home: cleanup" ;;
      *) manca "migrazione non finita: fase successiva $PROSSIMA" ;;
    esac
  fi

  sezione "cron dell'utente che nominano BASE"
  if ! command -v crontab > /dev/null 2>&1; then
    say "  crontab non disponibile"
  else
    CRON="$(crontab -l 2> /dev/null || true)"
    TROVATI="$(printf '%s\n' "$CRON" | grep -v '^[[:space:]]*#' | grep -F -e "$BASE" -e "$BASE_DATO" || true)"
    if [ -z "$TROVATI" ]; then
      say "  nessuno"
    else
      printf '%s\n' "$TROVATI" | while IFS= read -r riga; do
        giusta="$(sugg_cron "$riga")"
        say "  attuale:  $riga"
        case "$riga" in
          *'/usr/local/bin/php '* | *' php '*) say "  nota:     usa il PHP di sistema, non quello del dominio: meglio PHP_BIN" ;;
        esac
        if [ "$giusta" = "$riga" ]; then say "  corretto: (già su current)"
        else say "  corretto: $giusta"
        fi
        say ""
      done
      # la subshell del while non può toccare MANCA: si ricalcola qui
      for_cur="$(printf '%s\n' "$TROVATI" | while IFS= read -r riga; do [ "$(sugg_cron "$riga")" = "$riga" ] || echo x; done)"
      [ -z "$for_cur" ] || manca "cron da spostare su $BASE/current (vedi sopra): si cambiano dal pannello"
    fi
  fi

  sezione PHP
  leggi_php_dominio
  leggi_php_bin
  DOM_MM="$(ea_mm "$DOM_PHP")"
  if [ -n "$DOM_PHP" ]; then kv "PHP del dominio" "$DOM_PHP ($DOM_MM) · da $DOM_FONTE"
  else kv "PHP del dominio" "non determinato: guardalo in MultiPHP Manager"
  fi
  if [ -n "$PHP_BIN" ]; then
    kv "PHP_BIN" "$PHP_BIN ($(php_full "$PHP_BIN"))$([ -n "$PHP_OPT" ] && echo ' · passato con --php-bin' || echo ' · dedotto dal dominio')"
    if [ ! -x "$PHP_BIN" ]; then
      manca "PHP_BIN $PHP_BIN non è eseguibile"
    elif [ -n "$DOM_MM" ] && [ "$(php_mm "$PHP_BIN")" != "$DOM_MM" ]; then
      rosso "  PHP_BIN è $(php_mm "$PHP_BIN"), il dominio gira su $DOM_MM"
      manca "PHP_BIN e PHP del dominio non coincidono"
    fi
  else
    kv "PHP_BIN" "non determinato"
    manca "PHP_BIN: passalo con --php-bin, scegliendolo fra i binari elencati in PHP"
  fi
  say "  binari disponibili:"
  trovato=''
  for b in /opt/cpanel/ea-php*/root/usr/bin/php; do
    [ -x "$b" ] || continue
    trovato=1
    ea="$(printf '%s' "$b" | sed -n 's#^/opt/cpanel/\(ea-php[0-9]*\)/.*#\1#p')"
    segno=''; [ "$ea" = "$DOM_PHP" ] && segno='  <- dominio'
    printf '    %-40s %s%s\n' "$b" "$(php_full "$b")" "$segno"
  done
  [ -n "$trovato" ] || say "    nessun /opt/cpanel/ea-php*/root/usr/bin/php"
  if command -v php > /dev/null 2>&1; then
    kv "php nel PATH (di sistema)" "$(command -v php) ($(php_full "$(command -v php)")) · non usarlo come PHP_BIN"
  fi

  sezione "document root"
  URL="$(sito_url)"
  kv "URL del sito" "${URL:-non noto (APP_URL assente, passalo con --url)}"
  if [ -n "$DOM_ROOT" ]; then
    kv "document root (uapi)" "$DOM_ROOT"
    if [ "$DOM_ROOT" != "$BASE/current/public" ]; then
      manca "document root da cambiare in $BASE/current/public (ora $DOM_ROOT)"
    fi
  else
    kv "document root" "non leggibile da qui: controllalo nel pannello (deve essere $BASE/current/public)"
  fi

  sezione verdetto
  [ -d "$RELS" ] || manca "releases/ (fase shared)"
  [ -d "$SH" ] || manca "shared/ (fase shared)"
  [ -d "$TMPD" ] || manca "tmp/ (fase shared)"
  if [ ! -f "$SH/.env" ]; then manca "shared/.env: si compila a mano, questo script non lo scrive"
  elif [ -z "$(env_var "$SH/.env" APP_KEY)" ]; then manca "APP_KEY vuota in shared/.env"
  fi
  if [ ! -d "$SH/storage" ]; then manca "shared/storage/"
  else
    for d in $STORAGE_ALBERO; do [ -d "$SH/storage/$d" ] || manca "shared/storage/$d"; done
  fi
  if [ "$MODO" = existing ]; then
    nota "nel deploy.yml del progetto serve rotation-exclude: 000-legacy (vedi README)"
  fi

  if [ -z "$MANCA" ]; then
    say "${G}${B}pronto per il primo deploy: sì${N}"
  else
    say "${R}${B}pronto per il primo deploy: no${N}. Manca:"
    printf '%s' "$MANCA"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# bridge: current -> BASE. Da sola non cambia niente per nessuno: rende
# innocuo il cambio di document root che viene dopo.

bridge() {
  trappola_current || muori "bridge non lavora su una directory current"
  if current_su_base; then gia_fatto "current -> $BASE"; fi
  [ "$(tipo_current)" = assente ] || muori "$CUR esiste già e non punta a BASE ($(tipo_di "$CUR")): non la tocco"
  [ -f "$BASE/artisan" ] && [ -f "$BASE/public/index.php" ] || muori "$BASE non sembra un sito Laravel piatto (mancano artisan o public/index.php)"

  URL="$(sito_url)"
  prima=''
  if [ -n "$URL" ] && command -v curl > /dev/null 2>&1; then
    prima="$(codice "$URL$HEALTH")"
    say "prima:  $URL$HEALTH -> $prima"
  fi

  punta_current "$BASE" || muori "current non risolve in $BASE dopo la creazione"

  if [ -n "$prima" ]; then
    dopo="$(codice "$URL$HEALTH")"
    say "dopo:   $URL$HEALTH -> $dopo"
    [ "$dopo" = "$prima" ] || nota "il codice è cambiato: il ponte da solo non dovrebbe avere effetti visibili, controlla"
  else
    say "sonda saltata: URL non noto o curl assente"
  fi

  say ""
  say "prossimo passo: dal pannello cPanel, document root del dominio a"
  say "  $BASE/current/public"
  say "il sito serve gli stessi file attraverso current: se qualcosa non va, un clic riporta indietro."
  say "poi: shared"
}

# ---------------------------------------------------------------------------
# shared

# Prima di spostare .env e storage/ bisogna *sapere* che BASE non è più servito:
# se lo è, il .env finisce in una cartella raggiungibile dal web.
# - il token di root tornato vuol dire che BASE è ancora servito: ci si ferma;
# - la sonda pubblica è PHP perché, con current -> BASE, un document root BASE
#   (con un .htaccess che riscrive su public/) o BASE/public serve gli stessi
#   file di BASE/current/public. Solo DOCUMENT_ROOT li distingue.
sonde_document_root() {
  richiedi_curl
  URL="$(sito_url)"
  [ -n "$URL" ] || muori "URL del sito non noto: APP_URL assente nel .env, passalo con --url"
  say "sonde su $URL"

  tr="$(token root)"; tp="$(token public)"
  printf '%s\n' "$tr" > "$BASE/__probe-root.txt"
  SONDE="$SONDE $BASE/__probe-root.txt"
  printf "<?php echo '%s', '|', isset(\$_SERVER['DOCUMENT_ROOT']) ? \$_SERVER['DOCUMENT_ROOT'] : '';\n" "$tp" > "$BASE/public/__probe-public.php"
  SONDE="$SONDE $BASE/public/__probe-public.php"

  vr="$(corpo "$URL/__probe-root.txt" | tr -d '[:space:]')"
  vp="$(corpo "$URL/__probe-public.php" | tr -d '\r\n')"
  rimuovi_sonde
  say "  /__probe-root.txt   -> $(printf '%.80s' "${vr:-vuota}")"
  say "  /__probe-public.php -> $(printf '%.120s' "${vp:-vuota}")"

  if [ "$vr" = "$tr" ]; then
    muori "il dominio serve ancora $BASE: cambia il document root in $BASE/current/public prima di shared. Non ho creato niente"
  fi
  case "$vp" in
    "$tp|"*) ;;
    *) muori "la sonda pubblica non risponde: il dominio non serve $BASE/current/public. Non ho creato niente" ;;
  esac
  dr="${vp#"$tp|"}"; dr="${dr%/}"
  case "$dr" in
    */current/public) ;;
    *) muori "il document root è '$dr', non $BASE/current/public. Non ho creato niente" ;;
  esac
  [ "$(risolto "$dr")" = "$BASE/public" ] || muori "il document root '$dr' non risolve in $BASE/public. Non ho creato niente"
  say "  document root: $dr"
}

crea_albero_storage() {
  for d in $STORAGE_ALBERO; do
    [ -d "$SH/storage/$d" ] || { mkdir -p "$SH/storage/$d"; say "  creata shared/storage/$d"; }
  done
  chmod -R u+rwX "$SH/storage"
}

stampa_vars() {
  leggi_php_dominio
  leggi_php_bin
  app_name="$(env_var "$SH/.env" APP_NAME)"
  say ""
  say "${B}vars dell'Environment GitHub${N}"
  say "  RELEASES_PATH  $RELS"
  say "  SHARED_PATH    $SH"
  say "  CURRENT_PATH   $CUR"
  say "  TMP_PATH       $TMPD"
  # gli apostrofi dentro ${var:-...} fra doppi apici non sono portabili
  [ -n "$PHP_BIN" ] || PHP_BIN="<non determinato: lancia recon e scegli dall'elenco>"
  [ -n "$app_name" ] || app_name='<facoltativa: se assente il deploy usa il nome del repository>'
  say "  PHP_BIN        $PHP_BIN"
  say "  APP_NAME       $app_name"
  say ""
  say "${B}nel deploy.yml del progetto, sotto with:${N}"
  [ -n "$DOM_PHP" ] && say "  php-version: \"$(ea_mm "$DOM_PHP")\""
  if [ "$MODO" = existing ]; then
    say "  rotation-exclude: 000-legacy"
    say "  (senza questa riga la copia pre-migrazione è la prima release che la rotazione cancella)"
  fi
}

shared() {
  [ ! -e "$SH" ] || muori "$SH esiste già: shared non rifà niente, e rieseguibile non vuol dire che ripara uno stato a metà. Lancia recon"
  trappola_current || nota "current è una directory vera: shared prosegue, ma il primo deploy fallirà finché non la cancelli"

  if [ "$MODO" = existing ]; then
    current_su_base || muori "current non punta a $BASE: prima bridge, poi il cambio di document root"
    [ -f "$BASE/.env" ] && [ ! -L "$BASE/.env" ] || muori "$BASE/.env non è un file vero ($(tipo_di "$BASE/.env")): non so cosa spostare"
    [ -d "$BASE/storage" ] && [ ! -L "$BASE/storage" ] || muori "$BASE/storage non è una directory vera ($(tipo_di "$BASE/storage"))"
    sonde_document_root
  fi

  mkdir -p "$RELS" "$SH" "$TMPD"
  say "create releases/, shared/, tmp/"

  if [ "$MODO" = existing ]; then
    # .env: hard link e poi rename del symlink sopra il file. Il sito vecchio
    # non vede mai un istante senza .env, e legge lo stesso inode di prima.
    ln "$BASE/.env" "$SH/.env"
    ln -s shared/.env "$BASE/.env.setup-new"
    mv -Tf "$BASE/.env.setup-new" "$BASE/.env"
    chmod 600 "$SH/.env"
    # storage/ non si può collegare con un hard link: due rename ravvicinate,
    # con il symlink già pronto. Il sito continua a scrivere negli stessi inode.
    ln -s shared/storage "$BASE/storage.setup-new"
    mv "$BASE/storage" "$SH/storage"
    mv -Tf "$BASE/storage.setup-new" "$BASE/storage"
    crea_albero_storage
    for p in .env storage public/storage; do
      [ -e "$BASE/$p" ] || [ -L "$BASE/$p" ] || continue
      printf '  %-16s -> %s\n' "$p" "$(risolto "$BASE/$p")"
    done
  else
    mkdir -p "$SH/storage"
    crea_albero_storage
    [ -e "$BASE/.env" ] && nota "$BASE/.env esiste: in --new non lo sposto, il .env del layout è shared/.env"
    say "shared/.env non esiste: va compilato a mano, con APP_KEY valorizzata, e messo a 600"
  fi

  stampa_vars
  say ""
  if [ "$MODO" = existing ]; then say "poi: legacy"; else say "poi: recon, finché non dice pronto"; fi
}

# ---------------------------------------------------------------------------
# legacy: il sito piatto dentro releases/000-legacy, senza cancellare niente

spazio_sufficiente() {
  codice_kb=0
  for p in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    case "${p##*/}" in releases | shared | tmp | current | storage | .env) continue ;; esac
    k="$(du -sk "$p" 2> /dev/null | cut -f1)"
    codice_kb=$((codice_kb + ${k:-0}))
  done
  storage_kb="$(du -sk "$SH/storage" 2> /dev/null | cut -f1)"
  libero_kb="$(df -Pk "$BASE" | awk 'NR==2 { print $4 }')"
  # archivio non compresso nel caso peggiore, più la copia della release
  serve_kb=$((codice_kb * 2 + ${storage_kb:-0}))
  say "spazio: codice $((codice_kb / 1024)) MB, storage $((${storage_kb:-0} / 1024)) MB, servono fino a $((serve_kb / 1024)) MB, liberi $((libero_kb / 1024)) MB (df: la quota cPanel può essere più stretta)"
  [ "$libero_kb" -ge "$serve_kb" ]
}

# I path assoluti che config:cache ha scritto puntano a BASE/storage,
# BASE/resources... Dopo cleanup non esisterebbero più, e la copia smetterebbe
# di funzionare proprio quando è l'unica rete di sicurezza. Si riscrivono nella
# sola copia: il valore delle chiavi resta quello in cache, il .env non viene
# riletto.
riscrivi_config_cache() {
  cc="$LEGACY/bootstrap/cache/config.php"
  [ -f "$cc" ] || return 0
  e="$(printf '%s' "$BASE" | sed 's/[][\.*^$#]/\\&/g')"
  n="$(grep -o "'${e}[/']" "$cc" | wc -l | tr -d ' ')"
  sed -i -e "s#'$e/#'$LEGACY/#g" -e "s#'$e'#'$LEGACY'#g" "$cc"
  say "  bootstrap/cache/config.php: $n path in $BASE riscritti verso releases/000-legacy"
}

legacy() {
  trappola_current || muori "legacy non lavora su una directory current"
  [ "$(tipo_current)" = symlink ] || muori "current non esiste: prima bridge"
  [ "$(risolto "$CUR")" != "$LEGACY" ] || gia_fatto "current -> $LEGACY"
  current_su_base || muori "current risolve in $(risolto "$CUR"), né in $BASE né in $LEGACY: non lo tocco"
  [ -f "$SH/.env" ] && [ -d "$SH/storage" ] || muori "shared/.env o shared/storage mancano: prima shared"
  [ "$(risolto "$BASE/.env")" = "$SH/.env" ] && [ "$(risolto "$BASE/storage")" = "$SH/storage" ] \
    || muori "$BASE/.env e $BASE/storage non puntano a shared/: prima shared"
  originali_in_home || muori "in $BASE non c'è più il sito piatto"
  richiedi_curl
  URL="$(sito_url)"
  [ -n "$URL" ] || muori "URL del sito non noto: APP_URL assente in shared/.env, passalo con --url"

  RIPRESA=''
  if [ -d "$LEGACY" ] && [ -f "$ARCHIVIO" ]; then
    # l'unico stato a metà che si riprende: il passo 5 ha riportato current su
    # BASE senza cancellare niente
    RIPRESA=1
    say "ripresa: archivio e releases/000-legacy ci sono già, riparto dal passo 3"
  elif [ -e "$LEGACY" ]; then
    muori "$LEGACY esiste ma l'archivio no: non so da dove venga. Non tocco niente"
  elif [ -e "$ARCHIVIO" ]; then
    muori "$ARCHIVIO esiste ma $LEGACY no: stato a metà che non riparo. Spostalo altrove per rifare la fase"
  fi

  c="$(codice "$URL$HEALTH")"
  say "prima dello spostamento: $URL$HEALTH -> ${c:-000}"
  verde "${c:-000}" || muori "il sito non risponde già adesso: con current spostato non saprei distinguere la causa"

  if [ -z "$RIPRESA" ]; then
    spazio_sufficiente || muori "spazio insufficiente per archivio e copia"

    say "1. archivio in $ARCHIVIO"
    # -h dereferenzia: .env e storage/ entrano veri, così l'archivio è la
    # fotografia completa dello stato pre-migrazione. Si scrive a parte e si
    # rinomina, così un archivio a metà non passa mai per finito.
    rc=0
    (umask 077 && tar -czhf "$ARCHIVIO.part" -C "$BASE" \
      --exclude=./releases --exclude=./shared --exclude=./tmp --exclude=./current .) || rc=$?
    # 1 vuol dire file cambiati durante la lettura (log, sessioni): l'archivio
    # è comunque usabile
    case "$rc" in
      0) ;;
      1) nota "tar: alcuni file sono cambiati durante l'archiviazione (log, sessioni). L'archivio è valido" ;;
      *) rm -f "$ARCHIVIO.part"; muori "tar è uscito con $rc: nessun archivio, niente di modificato" ;;
    esac
    chmod 600 "$ARCHIVIO.part"
    mv "$ARCHIVIO.part" "$ARCHIVIO"
    say "   $(du -h "$ARCHIVIO" | cut -f1), permessi $(stat -c '%a' "$ARCHIVIO")"

    say "2. estrazione in $LEGACY, senza .env e storage/"
    # public/storage: se era un symlink, -h l'ha trasformato in una copia di
    # storage/app/public. Nella release torna symlink verso shared/. Se era una
    # directory vera, invece, sono file del sito e si portano.
    ESCL_PS=''
    [ -L "$BASE/public/storage" ] && ESCL_PS='--exclude=./public/storage'
    rm -rf "$LEGACY.part"
    mkdir -p "$LEGACY.part"
    # shellcheck disable=SC2086
    tar -xpzf "$ARCHIVIO" -C "$LEGACY.part" --exclude=./.env --exclude=./storage $ESCL_PS \
      || { rm -rf "$LEGACY.part"; muori "estrazione fallita: current non è stato toccato"; }
    mv "$LEGACY.part" "$LEGACY"
    riscrivi_config_cache
  fi

  say "3. collegamenti verso shared/, con target relativo"
  # Non dall'archivio: BASE/.env -> shared/.env è relativo, e dentro la
  # release punterebbe a releases/000-legacy/shared/.env.
  ln -srfT "$SH/storage" "$LEGACY/storage"
  ln -srfT "$SH/.env" "$LEGACY/.env"
  if [ -L "$BASE/public/storage" ] || [ ! -e "$LEGACY/public/storage" ]; then
    ln -srfT "$SH/storage/app/public" "$LEGACY/public/storage"
  fi
  for p in .env storage public/storage; do
    printf '   %-16s -> %s\n' "$p" "$(risolto "$LEGACY/$p")"
  done
  for p in artisan public/index.php vendor/autoload.php; do
    [ -f "$LEGACY/$p" ] || muori "nella copia manca $p: current non è stato toccato"
  done

  say "4. current -> $LEGACY"
  punta_current "$LEGACY" || {
    punta_current "$BASE" || true
    muori "lo swap non ha avuto effetto: current riportato su $BASE"
  }

  say "5. il sito risponde da releases/000-legacy?"
  if sonda_release "$LEGACY"; then
    say ""
    say "${G}fatto${N}: il sito risponde da $LEGACY. La home è ancora intatta."
    say "rete di sicurezza fino a cleanup:  ln -sfn '$BASE' '$CUR.new' && mv -Tf '$CUR.new' '$CUR'"
    say "poi: cleanup"
  else
    say "   il sito non risponde: riporto current su $BASE"
    punta_current "$BASE" || rosso "ATTENZIONE: current non risolve in $BASE, sistemalo a mano: ln -sfn '$BASE' '$CUR'"
    c="$(codice "$URL$HEALTH")"
    say "   $URL$HEALTH -> ${c:-000}"
    muori "legacy fermata al passo 5. Non ho cancellato niente: archivio e copia restano, la fase si rilancia"
  fi
}

# ---------------------------------------------------------------------------
# cleanup: via i file originali dalla home

cleanup() {
  [ "$(tipo_current)" = symlink ] && [ "$(risolto "$CUR")" = "$LEGACY" ] \
    || muori "current non risolve in $LEGACY ($(tipo_di "$CUR")): cleanup non gira"
  [ -f "$ARCHIVIO" ] || muori "manca $ARCHIVIO: senza archivio non cancello niente"
  originali_in_home || gia_fatto "in $BASE non ci sono più i file originali"
  richiedi_curl
  URL="$(sito_url)"
  [ -n "$URL" ] || muori "URL del sito non noto: APP_URL assente in shared/.env, passalo con --url"

  sonda_release "$LEGACY" || muori "la sonda non è verde: cleanup non cancella niente"

  # Si cancella solo quello che è nell'archivio, voce per voce, e solo se la
  # copia ce l'ha: ciò che è comparso dopo resta dov'è e viene elencato. Le
  # voci si leggono una per riga, perché un nome può contenere spazi.
  VOCI="$(tar -tzf "$ARCHIVIO" | sed -e 's#^\./##' -e 's#/.*##' | grep -v '^\.\{0,1\}$' | sort -u)"
  while IFS= read -r v; do
    case "$v" in '' | .env | storage) continue ;; esac
    [ -e "$LEGACY/$v" ] || [ -L "$LEGACY/$v" ] || muori "'$v' è nell'archivio ma non in $LEGACY: non cancello niente"
  done << EOF
$VOCI
EOF
  for v in .env storage; do
    [ ! -e "$BASE/$v" ] || [ -L "$BASE/$v" ] || muori "$BASE/$v non è un symlink: non cancello niente"
  done

  while IFS= read -r v; do
    case "$v" in '' | releases | shared | tmp | current) continue ;; esac
    [ -e "$BASE/$v" ] || [ -L "$BASE/$v" ] || continue
    # rm su un symlink toglie il collegamento, non il target in shared/
    rm -rf "${BASE:?}/$v"
    say "  rimosso $v"
  done << EOF
$VOCI
EOF

  say "restano in $BASE:"
  for p in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    case "${p##*/}" in
      releases | shared | tmp | current) say "  ${p##*/}" ;;
      *) say "  ${p##*/}  ${Y}<- non era nell'archivio: lasciato${N}" ;;
    esac
  done

  c="$(codice "$URL$HEALTH")"
  say "$URL$HEALTH -> ${c:-000}"
  verde "${c:-000}" || rosso "il sito non risponde dopo cleanup: la copia è in $LEGACY, e in ultima istanza c'è $ARCHIVIO"
  say ""
  say "rete di sicurezza da qui:  ln -sfn '$LEGACY' '$CUR.new' && mv -Tf '$CUR.new' '$CUR'"
  say "poi: spostare i cron su $BASE/current/artisan, rotation-exclude: 000-legacy nel deploy.yml,"
  say "recon finché non dice pronto, e primo deploy sullo stesso commit già in produzione."
}

"$FASE"
