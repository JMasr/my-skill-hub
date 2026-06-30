#!/usr/bin/env bash
# repo-topology.sh — Captura la topología git + GitLab del repositorio actual.
#
# Genérico: autodetecta el proyecto desde el remote git del directorio actual.
# No hardcodea owner/repo. Pensado para que un agente entienda el repo ANTES de actuar.
#
# Uso:
#   repo-topology.sh [--json] [--remote <name>]
#     (sin flags)  -> reporte legible para humanos/agente
#     --json       -> objeto JSON con toda la topología (para consumo programático)
#
# Requisitos: git, glab (autenticado), jq.
set -euo pipefail

REMOTE_NAME="origin"
OUTPUT="human"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)   OUTPUT="json"; shift ;;
    --remote) REMOTE_NAME="${2:?--remote requiere un valor}"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
  esac
done

# --- Dependencias ---
for dep in git glab jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: falta '$dep' en el PATH." >&2; exit 1; }
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: no es un repositorio git." >&2; exit 1; }

# --- Parseo del remote -> host + project path ---
REMOTE_URL="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || true)"
[ -n "$REMOTE_URL" ] || { echo "ERROR: remote '$REMOTE_NAME' no encontrado." >&2; exit 1; }

url="${REMOTE_URL%.git}"
case "$url" in
  git@*:*)             HOST="${url#git@}"; HOST="${HOST%%:*}"; PROJECT_PATH="${url#*:}" ;;
  ssh://*)             rest="${url#ssh://}"; rest="${rest#*@}"; HOST="${rest%%/*}"; HOST="${HOST%%:*}"; PROJECT_PATH="${rest#*/}" ;;
  https://*|http://*)  rest="${url#*://}"; rest="${rest#*@}"; HOST="${rest%%/*}"; PROJECT_PATH="${rest#*/}" ;;
  *)                   HOST=""; PROJECT_PATH="$url" ;;
esac
# Codificar el path del proyecto para la API (/ -> %2F)
ENC_PATH="${PROJECT_PATH//\//%2F}"
[ -n "$HOST" ] && export GITLAB_HOST="$HOST"

# Helper API: silencioso, devuelve "{}"/"[]" en error para no romper el reporte
api() { glab api "$1" 2>/dev/null || echo "${2:-{}}"; }

# --- Datos git locales ---
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
LOCAL_BRANCHES="$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | paste -sd, - || true)"
REMOTE_BRANCHES="$(git for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE_NAME" 2>/dev/null | sed "s#^$REMOTE_NAME/##" | grep -v '^HEAD$' | paste -sd, - || true)"
LAST_COMMITS="$(git log --oneline -5 2>/dev/null || true)"

# --- Datos GitLab ---
PROJECT_JSON="$(api "projects/$ENC_PATH")"
PROTECTED_JSON="$(api "projects/$ENC_PATH/protected_branches" "[]")"
LABELS_JSON="$(api "projects/$ENC_PATH/labels?per_page=100" "[]")"
MILESTONES_JSON="$(api "projects/$ENC_PATH/milestones?per_page=100" "[]")"
ISSUES_OPEN_JSON="$(api "projects/$ENC_PATH/issues?state=opened&per_page=100" "[]")"
MRS_OPEN_JSON="$(api "projects/$ENC_PATH/merge_requests?state=opened&per_page=100" "[]")"
RUNNERS_JSON="$(api "projects/$ENC_PATH/runners?per_page=50" "[]")"
DEFAULT_BRANCH="$(echo "$PROJECT_JSON" | jq -r '.default_branch // "?"')"
PIPELINES_JSON="$(api "projects/$ENC_PATH/pipelines?ref=$DEFAULT_BRANCH&per_page=5" "[]")"

if [ "$OUTPUT" = "json" ]; then
  jq -n \
    --arg host "$HOST" --arg path "$PROJECT_PATH" --arg remote "$REMOTE_URL" \
    --arg cur "$CUR_BRANCH" --arg lb "$LOCAL_BRANCHES" --arg rb "$REMOTE_BRANCHES" \
    --argjson project "$PROJECT_JSON" \
    --argjson protected "$PROTECTED_JSON" \
    --argjson labels "$LABELS_JSON" \
    --argjson milestones "$MILESTONES_JSON" \
    --argjson issues_open "$ISSUES_OPEN_JSON" \
    --argjson mrs_open "$MRS_OPEN_JSON" \
    --argjson runners "$RUNNERS_JSON" \
    --argjson pipelines "$PIPELINES_JSON" \
    '{
      git: { host: $host, project_path: $path, remote_url: $remote,
             current_branch: $cur, local_branches: ($lb|split(",")), remote_branches: ($rb|split(",")) },
      project: ($project | {id, path_with_namespace, default_branch, visibility,
                 issues_enabled, merge_method, shared_runners_enabled,
                 access_level: (.permissions.project_access.access_level // null)}),
      protected_branches: [ $protected[] | { name,
                              push: [.push_access_levels[]?.access_level_description],
                              merge: [.merge_access_levels[]?.access_level_description] } ],
      labels: [ $labels[] | {name, color, description} ],
      milestones: { active: [ $milestones[] | select(.state=="active") | {iid, id, title, due_date} ],
                    closed_count: ([ $milestones[] | select(.state=="closed") ] | length) },
      issues_open: { count: ($issues_open|length),
                     items: [ $issues_open[] | {iid, title, labels, milestone: (.milestone.title // null)} ] },
      merge_requests_open: [ $mrs_open[] | {iid, title, source_branch, target_branch, milestone: (.milestone.title // null)} ],
      runners: [ $runners[] | {id, description, online, status, runner_type} ],
      recent_pipelines: [ $pipelines[] | {id, status, ref, sha: (.sha[0:8])} ]
    }'
  exit 0
fi

# --- Reporte legible ---
line() { printf '%s\n' "------------------------------------------------------------"; }
echo "============================================================"
echo " TOPOLOGÍA DEL REPOSITORIO"
echo "============================================================"
echo "Host:            $HOST"
echo "Proyecto:        $PROJECT_PATH"
echo "Project ID:      $(echo "$PROJECT_JSON" | jq -r '.id // "?"')"
echo "Default branch:  $DEFAULT_BRANCH"
echo "Visibilidad:     $(echo "$PROJECT_JSON" | jq -r '.visibility // "?"')"
echo "Issues enabled:  $(echo "$PROJECT_JSON" | jq -r '.issues_enabled // "?"')"
echo "Merge method:    $(echo "$PROJECT_JSON" | jq -r '.merge_method // "?"')"
echo "Shared runners:  $(echo "$PROJECT_JSON" | jq -r '.shared_runners_enabled // "?"')"
echo "Tu access level: $(echo "$PROJECT_JSON" | jq -r '.permissions.project_access.access_level // "?"') (40=Maintainer, 50=Owner)"
line
echo "GIT LOCAL"
echo "  Rama actual:     $CUR_BRANCH"
echo "  Ramas locales:   $LOCAL_BRANCHES"
echo "  Ramas remotas:   $REMOTE_BRANCHES"
echo "  Últimos commits:"
echo "$LAST_COMMITS" | sed 's/^/    /'
line
echo "MODELO DE RAMAS (detección)"
echo "$REMOTE_BRANCHES" | grep -qw develop && echo "  develop:  presente" || echo "  develop:  AUSENTE (¿crear rama de integración?)"
echo "$REMOTE_BRANCHES" | grep -qw main && echo "  main:     presente" || echo "  main:     ausente"
line
echo "PROTECTED BRANCHES"
echo "$PROTECTED_JSON" | jq -r '
  if length==0 then "  (ninguna protegida)"
  else .[] | "  \(.name): push=\([.push_access_levels[]?.access_level_description]|join("/")) merge=\([.merge_access_levels[]?.access_level_description]|join("/"))"
  end'
line
echo "LABELS ($(echo "$LABELS_JSON" | jq 'length'))"
echo "$LABELS_JSON" | jq -r '.[] | "  - \(.name)  (\(.color))"'
line
echo "MILESTONES"
echo "$MILESTONES_JSON" | jq -r '
  ([.[]|select(.state=="active")]) as $a |
  if ($a|length)==0 then "  Activos: (ninguno)"
  else "  Activos:", ($a[]|"    #\(.iid) \(.title)  due=\(.due_date // "-")") end,
  "  Cerrados: \([.[]|select(.state=="closed")]|length)"'
line
echo "ISSUES ABIERTAS ($(echo "$ISSUES_OPEN_JSON" | jq 'length')) [tope 100]"
echo "$ISSUES_OPEN_JSON" | jq -r '
  if length==0 then "  (ninguna)"
  else .[] | "  #\(.iid) [\(.labels|join(","))] \(.title)  (milestone: \(.milestone.title // "-"))" end'
line
echo "MERGE REQUESTS ABIERTOS ($(echo "$MRS_OPEN_JSON" | jq 'length'))"
echo "$MRS_OPEN_JSON" | jq -r '
  if length==0 then "  (ninguno)"
  else .[] | "  !\(.iid) \(.source_branch) -> \(.target_branch): \(.title)" end'
line
echo "RUNNERS DISPONIBLES"
echo "$RUNNERS_JSON" | jq -r '
  if length==0 then "  (NINGUNO habilitado -> los pipelines quedarán pending)"
  else .[] | "  id \(.id) | \(.runner_type) | online=\(.online) | \(.description)" end'
line
echo "PIPELINES RECIENTES (default branch)"
echo "$PIPELINES_JSON" | jq -r '
  if length==0 then "  (ninguno)"
  else .[] | "  \(.id) \(.status) \(.ref) \(.sha[0:8])" end'
echo "============================================================"
