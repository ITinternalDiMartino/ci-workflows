#!/usr/bin/env bash
# Verifica che ogni riferimento a un workflow di ci-workflows punti a un file che
# esiste in questa copia del repository.
#
# Riferimenti raccolti:
#   - i workflow di tutti i repository non archiviati dell'organizzazione, sul
#     loro branch predefinito (letti via GraphQL, non con la ricerca di codice,
#     che non indicizza tutti i repository);
#   - gli esempi in project_example e i workflow di questo stesso repository.
#
# Uso: scripts/check-workflow-references.sh
# Ambiente:
#   GH_TOKEN  token con lettura dei contenuti dei repository dell'organizzazione
#   ORG       organizzazione (predefinita: ITinternalDiMartino)
#   STRICT    "true": i riferimenti rotti sono errori e lo script esce con 1;
#             altrimenti sono avvisi e lo script esce con 0
#
# Dipendenze: gh, jq.
set -euo pipefail

ORG="${ORG:-ITinternalDiMartino}"
STRICT="${STRICT:-false}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN="${ORG}/ci-workflows/\\.github/workflows/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+"

refs="$(mktemp)"
trap 'rm -f "$refs"' EXIT

# Stampa "<repository>\t<file>\t<workflow>" per ogni riferimento trovato nel testo
# letto da stdin.
extract() {
  grep -oiE "$PATTERN" | sed -E 's|^.*/workflows/([^@]+)@.*$|\1|' |
    awk -v r="$1" -v f="$2" '{ print r "\t" f "\t" $0 }'
}

# Repository dell'organizzazione, 50 per pagina.
# shellcheck disable=SC2016 # le variabili sono di GraphQL, non della shell
query='query($org: String!, $after: String) {
  organization(login: $org) {
    repositories(first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        isArchived
        object(expression: "HEAD:.github/workflows") {
          ... on Tree { entries { path object { ... on Blob { text } } } }
        }
      }
    }
  }
}'

after=""
while :; do
  args=(-f query="$query" -F org="$ORG")
  [ -n "$after" ] && args+=(-F after="$after")
  page="$(gh api graphql "${args[@]}")"

  # Il repository corrente si controlla dalla copia locale, più sotto.
  jq -c '.data.organization.repositories.nodes[]
    | select(.isArchived | not)
    | select(.name != "ci-workflows")
    | .name as $repo
    | (.object.entries // [])[]
    | {repo: $repo, path: .path, text: (.object.text // "")}' <<<"$page" |
    while IFS= read -r entry; do
      jq -r .text <<<"$entry" |
        extract "$(jq -r .repo <<<"$entry")" "$(jq -r .path <<<"$entry")" >>"$refs" || true
    done

  [ "$(jq -r .data.organization.repositories.pageInfo.hasNextPage <<<"$page")" = true ] || break
  after="$(jq -r .data.organization.repositories.pageInfo.endCursor <<<"$page")"
done

for f in "$ROOT"/project_example/*.y*ml "$ROOT"/.github/workflows/*.y*ml; do
  [ -f "$f" ] || continue
  extract "ci-workflows" "${f#"$ROOT"/}" <"$f" >>"$refs" || true
done

total=0
missing=0
while IFS=$'\t' read -r repo file workflow; do
  total=$((total + 1))
  [ -f "$ROOT/.github/workflows/$workflow" ] && continue
  missing=$((missing + 1))
  msg="$repo: $file chiama $workflow, che non esiste in ci-workflows"
  if [ "$STRICT" = true ]; then
    echo "::error title=Workflow inesistente::$msg"
  else
    echo "::warning title=Workflow inesistente::$msg"
  fi
done < <(sort -u "$refs")

summary="Riferimenti a workflow di ci-workflows: $total, di cui $missing verso file inesistenti."
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Riferimenti ai workflow"
    echo
    echo "$summary"
    if [ "$missing" -gt 0 ]; then
      echo
      echo "| Repository | File | Workflow mancante |"
      echo "|---|---|---|"
      sort -u "$refs" | while IFS=$'\t' read -r repo file workflow; do
        [ -f "$ROOT/.github/workflows/$workflow" ] || echo "| $repo | \`$file\` | \`$workflow\` |"
      done
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$missing" -gt 0 ] && [ "$STRICT" = true ]; then
  exit 1
fi
