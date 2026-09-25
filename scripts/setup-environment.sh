#!/usr/bin/env bash
# setup-environment.sh - crea l'Environment GitHub di un progetto con le vars e
# i secret che chiede laravel-projects-deploy.yml.
#
# Gira sul proprio computer, con la CLI gh autenticata come admin del
# repository. I valori non si scrivono a mano:
#   - le vars le calcola il server, con la fase vars di setup-releases.sh,
#     quindi PHP_BIN è il PHP del dominio e non quello di `which php`;
#   - SSH_KNOWN_HOSTS viene dal proprio known_hosts, cioè dalla chiave dell'host
#     che si è già accettata collegandosi, non da un ssh-keyscan che si fida di
#     chiunque risponda in quel momento;
#   - SSH_PRIVATE_KEY è la chiave di deploy passata con --key, già autorizzata
#     sul server: lo script lo verifica collegandosi come farà il runner, ma non
#     la autorizza.
#
# Uso:
#   scripts/setup-environment.sh --repo ORG/PROGETTO --env production \
#     --ssh utente@host [--port 2222] --base /home/utente/dominio.it \
#     --key ~/.ssh/deploy_progetto [opzioni]
#
# Opzioni:
#   --php-bin PATH    PHP_BIN al posto di quello dedotto dal server
#   --app-name NOME   APP_NAME al posto di quello letto da shared/.env
#   --dry-run         mostra cosa farebbe e si ferma
#   --yes             non chiede conferma (necessario se stdin non è un terminale)

set -euo pipefail
# array associativi ed espansione di array vuoti con set -u: bash 4.4 o più.
# Su macOS il bash di sistema è il 3.2: brew install bash
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  printf 'ERRORE: serve bash 4.4 o più, questo è %s\n' "$BASH_VERSION" >&2
  exit 1
fi

say() { printf '%s\n' "$*"; }
nota() { printf '  !!  %s\n' "$*"; }
muori() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

REPO=''; ENV_NAME=''; SSH_DEST=''; PORT=''; BASE=''; KEY=''
PHP_OPT=''; APP_OPT=''; DRY=''; YES=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --env | --ssh | --port | --base | --key | --php-bin | --app-name)
      [ -n "${2:-}" ] || muori "$1 vuole un valore"
      case "$1" in
        --repo) REPO="$2" ;;
        --env) ENV_NAME="$2" ;;
        --ssh) SSH_DEST="$2" ;;
        --port) PORT="$2" ;;
        --base) BASE="$2" ;;
        --key) KEY="$2" ;;
        --php-bin) PHP_OPT="$2" ;;
        --app-name) APP_OPT="$2" ;;
      esac
      shift
      ;;
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) muori "argomento sconosciuto: $1 (--help per l'uso)" ;;
  esac
  shift
done

[ -n "$REPO" ] || muori "manca --repo"
[ -n "$ENV_NAME" ] || muori "manca --env"
[ -n "$SSH_DEST" ] || muori "manca --ssh"
[ -n "$BASE" ] || muori "manca --base"
[ -n "$KEY" ] || muori "manca --key: la chiave privata di deploy, già autorizzata sul server"
case "$REPO" in */*) ;; *) muori "--repo vuole la forma ORGANIZZAZIONE/REPOSITORY" ;; esac
case "$BASE" in /*) ;; *) muori "--base deve essere un percorso assoluto sul server" ;; esac
case "$PORT" in '' | *[!0-9]*) [ -z "$PORT" ] || muori "--port vuole un numero" ;; esac

QUI="$(cd "$(dirname "$0")" && pwd)"
SETUP_RELEASES="$QUI/setup-releases.sh"
[ -f "$SETUP_RELEASES" ] || muori "manca $SETUP_RELEASES: lo script va lanciato dal repository ci-workflows"

for t in gh ssh ssh-keygen; do
  command -v "$t" > /dev/null 2>&1 || muori "manca $t"
done
gh auth status > /dev/null 2>&1 || muori "gh non è autenticato: gh auth login"

LAVORO="$(mktemp -d)"
trap 'rm -rf "$LAVORO"' EXIT

# ---------------------------------------------------------------------------
# chiave di deploy

[ -f "$KEY" ] || muori "la chiave $KEY non esiste"
# ssh rifiuta una chiave leggibile da altri, e il messaggio si perderebbe dietro
# BatchMode come un generico "Permission denied"
case "$(stat -c '%a' "$KEY" 2> /dev/null || stat -f '%Lp' "$KEY")" in
  600 | 400) ;;
  *) muori "la chiave $KEY è leggibile da altri utenti: chmod 600 '$KEY'" ;;
esac
# Senza newline finale la chiave non si legge, né qui né sul runner ("error in
# libcrypto"): si lavora su una copia che ce l'ha, ed è quella che va nel
# secret.
cp "$KEY" "$LAVORO/key"
chmod 600 "$LAVORO/key"
[ -z "$(tail -c1 "$LAVORO/key")" ] || printf '\n' >> "$LAVORO/key"
# -P '' senza passphrase: se la chiave ne ha una fallisce invece di chiederla,
# ed è giusto così, perché il runner non potrebbe inserirla
if ! ssh-keygen -y -P '' -f "$LAVORO/key" > "$LAVORO/key.pub" 2> /dev/null; then
  muori "$KEY non è una chiave privata leggibile, o è protetta da passphrase: il deploy non può usarla"
fi
FINGERPRINT="$(ssh-keygen -l -f "$LAVORO/key.pub")"

# ---------------------------------------------------------------------------
# destinazione, risolta come la risolve ssh (alias, porta, utente di
# ~/.ssh/config), perché nei secret vanno i valori veri: il runner non ha la
# configurazione di questo computer

G_ARGS=()
[ -n "$PORT" ] && G_ARGS=(-p "$PORT")
SSH_G="$(ssh -G "${G_ARGS[@]}" "$SSH_DEST")"
campo() { printf '%s\n' "$SSH_G" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }
S_HOST="$(campo hostname)"
S_PORT="$(campo port)"
S_USER="$(campo user)"
[ -n "$S_HOST" ] && [ -n "$S_PORT" ] && [ -n "$S_USER" ] || muori "non riesco a risolvere $SSH_DEST"

if [ "$S_PORT" = 22 ]; then HOSTKEY_NAME="$S_HOST"; else HOSTKEY_NAME="[$S_HOST]:$S_PORT"; fi
: > "$LAVORO/known_hosts"
for f in $(campo userknownhostsfile); do
  f="${f/#\~/$HOME}"
  [ -f "$f" ] || continue
  ssh-keygen -F "$HOSTKEY_NAME" -f "$f" 2> /dev/null | grep -v '^#' >> "$LAVORO/known_hosts" || true
done
[ -s "$LAVORO/known_hosts" ] || muori "$HOSTKEY_NAME non è nel tuo known_hosts: collegati una volta a mano (ssh -p $S_PORT $S_USER@$S_HOST), verifica l'impronta con quella del pannello e rilancia"

# Stesse condizioni del runner: nessuna configurazione locale, solo questa
# chiave, solo queste righe di known_hosts, nessuna domanda.
RSSH=(ssh -F /dev/null -i "$LAVORO/key" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$LAVORO/known_hosts"
  -o ConnectTimeout=15 -p "$S_PORT" "$S_USER@$S_HOST")

say "destinazione: $S_USER@$S_HOST porta $S_PORT"
say "chiave:       $FINGERPRINT"
say "known_hosts:  $(wc -l < "$LAVORO/known_hosts" | tr -d ' ') righe per $HOSTKEY_NAME"
if ! "${RSSH[@]}" true 2> "$LAVORO/ssh.err"; then
  sed 's/^/  ssh: /' "$LAVORO/ssh.err" >&2
  say "chiave pubblica corrispondente:" >&2
  sed 's/^/  /' "$LAVORO/key.pub" >&2
  muori "il server non accetta la chiave come la userebbe il deploy. Se 'Permission denied': in cPanel, SSH Access > Manage SSH Keys > Import Key, incolla la chiave pubblica qui sopra e premi Authorize"
fi
say "connessione:  ok, come dal runner"

# ---------------------------------------------------------------------------
# vars, calcolate dal server

V_ARGS=(vars "$BASE")
[ -n "$PHP_OPT" ] && V_ARGS+=(--php-bin "$PHP_OPT")
if ! "${RSSH[@]}" "sh -s -- ${V_ARGS[*]}" < "$SETUP_RELEASES" > "$LAVORO/vars" 2> "$LAVORO/vars.err"; then
  cat "$LAVORO/vars" "$LAVORO/vars.err" >&2
  muori "la fase vars di setup-releases.sh è fallita sul server"
fi
var() { sed -n "s/^$1=//p" "$LAVORO/vars" | head -n1; }

declare -A NUOVE
for v in RELEASES_PATH SHARED_PATH CURRENT_PATH TMP_PATH PHP_BIN; do NUOVE[$v]="$(var "$v")"; done
APP_NAME_V="${APP_OPT:-$(var APP_NAME)}"
[ -n "${NUOVE[PHP_BIN]}" ] || muori "il server non sa dire il PHP del dominio: lancia recon di setup-releases.sh, scegli il binario e passalo con --php-bin"
[ "$(var SHARED_ENV)" = 1 ] || nota "shared/.env non esiste ancora sul server: il deploy fallirà finché non c'è (setup-releases.sh shared, poi lo si compila)"
[ -n "$(var DOMAIN_PHP)" ] && say "PHP del dominio: $(var DOMAIN_PHP) (php-version nel deploy.yml)"

# ---------------------------------------------------------------------------
# stato attuale su GitHub

ENV_ESISTE=''
gh api "repos/$REPO/environments/$ENV_NAME" --silent 2> /dev/null && ENV_ESISTE=1
declare -A ATTUALI
if [ -n "$ENV_ESISTE" ]; then
  while IFS=$'\t' read -r n v; do
    [ -n "$n" ] && ATTUALI[$n]="$v"
  done < <(gh variable list --env "$ENV_NAME" --repo "$REPO" --json name,value --jq '.[] | [.name, .value] | @tsv')
  SEGRETI="$(gh secret list --env "$ENV_NAME" --repo "$REPO" --json name --jq '.[].name')"
else
  SEGRETI=''
fi

# GH_TOKEN di solito è dell'organizzazione: qui si controlla solo che il
# repository lo veda, da una qualunque delle tre provenienze
GH_TOKEN_DA=''
printf '%s\n' "$SEGRETI" | grep -qx GH_TOKEN && GH_TOKEN_DA="environment"
[ -z "$GH_TOKEN_DA" ] && gh secret list --repo "$REPO" --json name --jq '.[].name' 2> /dev/null | grep -qx GH_TOKEN && GH_TOKEN_DA="repository"
[ -z "$GH_TOKEN_DA" ] && gh api "repos/$REPO/actions/organization-secrets" --jq '.secrets[].name' 2> /dev/null | grep -qx GH_TOKEN && GH_TOKEN_DA="organizzazione"

# ---------------------------------------------------------------------------
# piano

say ""
if [ -n "$ENV_ESISTE" ]; then say "Environment '$ENV_NAME' su $REPO: esiste"
else say "Environment '$ENV_NAME' su $REPO: da creare"
fi

say ""
say "vars"
PIANO_VARS=()
riga_var() {
  local n="$1" nuovo="$2" azione
  if [ -z "${ATTUALI[$n]+x}" ]; then azione="crea"
  elif [ "${ATTUALI[$n]}" = "$nuovo" ]; then azione="uguale"
  else azione="aggiorna (era ${ATTUALI[$n]})"
  fi
  printf '  %-14s %-50s %s\n' "$n" "$nuovo" "$azione"
  [ "$azione" = uguale ] || PIANO_VARS+=("$n")
}
for v in RELEASES_PATH SHARED_PATH CURRENT_PATH TMP_PATH PHP_BIN; do riga_var "$v" "${NUOVE[$v]}"; done
if [ -n "$APP_NAME_V" ]; then
  NUOVE[APP_NAME]="$APP_NAME_V"
  riga_var APP_NAME "$APP_NAME_V"
else
  printf '  %-14s %-50s %s\n' APP_NAME "" "non impostata: il deploy usa il nome del repository"
fi

say ""
say "secret (i valori non si leggono da GitHub: quelli esistenti vengono sovrascritti)"
for s in SSH_HOST SSH_USER SSH_PORT SSH_KNOWN_HOSTS SSH_PRIVATE_KEY; do
  case "$s" in
    SSH_HOST) mostra="$S_HOST" ;;
    SSH_USER) mostra="$S_USER" ;;
    SSH_PORT) mostra="$S_PORT" ;;
    SSH_KNOWN_HOSTS) mostra="$(wc -l < "$LAVORO/known_hosts" | tr -d ' ') righe per $HOSTKEY_NAME" ;;
    SSH_PRIVATE_KEY) mostra="$KEY" ;;
  esac
  if printf '%s\n' "$SEGRETI" | grep -qx "$s"; then azione="sovrascrive"; else azione="crea"; fi
  printf '  %-16s %-48s %s\n' "$s" "$mostra" "$azione"
done
if [ -n "$GH_TOKEN_DA" ]; then
  printf '  %-16s %-48s %s\n' GH_TOKEN "" "non toccato: il repository lo vede ($GH_TOKEN_DA)"
else
  printf '  %-16s %-48s %s\n' GH_TOKEN "" "NON TROVATO: va creato a parte, di solito come secret dell'organizzazione"
fi

if [ -n "$DRY" ]; then
  say ""
  say "--dry-run: niente è stato modificato"
  exit 0
fi

if [ -z "$YES" ]; then
  [ -t 0 ] || muori "stdin non è un terminale: rilancia con --yes per procedere senza conferma"
  printf '\nprocedo? [s/N] '
  read -r risposta
  case "$risposta" in s | S | si | sì) ;; *) say "niente è stato modificato"; exit 0 ;; esac
fi

# ---------------------------------------------------------------------------
# scrittura

say ""
if [ -z "$ENV_ESISTE" ]; then
  gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --silent
  say "creato l'Environment $ENV_NAME"
fi

for v in "${PIANO_VARS[@]}"; do
  gh variable set "$v" --env "$ENV_NAME" --repo "$REPO" --body "${NUOVE[$v]}"
done

gh secret set SSH_HOST --env "$ENV_NAME" --repo "$REPO" --body "$S_HOST"
gh secret set SSH_USER --env "$ENV_NAME" --repo "$REPO" --body "$S_USER"
gh secret set SSH_PORT --env "$ENV_NAME" --repo "$REPO" --body "$S_PORT"
gh secret set SSH_KNOWN_HOSTS --env "$ENV_NAME" --repo "$REPO" < "$LAVORO/known_hosts"
gh secret set SSH_PRIVATE_KEY --env "$ENV_NAME" --repo "$REPO" < "$LAVORO/key"

say ""
say "fatto. Environment $ENV_NAME su $REPO:"
say "  vars:   $(gh variable list --env "$ENV_NAME" --repo "$REPO" --json name --jq '[.[].name] | join(" ")')"
say "  secret: $(gh secret list --env "$ENV_NAME" --repo "$REPO" --json name --jq '[.[].name] | join(" ")')"
[ -n "$GH_TOKEN_DA" ] || nota "manca ancora GH_TOKEN"
