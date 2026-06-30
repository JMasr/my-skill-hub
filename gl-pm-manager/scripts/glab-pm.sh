#!/usr/bin/env bash
# glab-pm.sh — Operaciones de Project Management para GitLab vía glab CLI.
#
# Genérico: el proyecto se autodetecta desde el remote git del repo actual.
# Encapsula el flujo que un PM/agente necesita en un sprint GitFlow:
#   issues bajo milestone, labels, MR -> develop con Closes, pipeline verde,
#   merge, y release develop -> main + tag.
#
# Uso: glab-pm.sh <comando> [args]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.json"

# --- Dependencias y contexto ---
for dep in git glab jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: falta '$dep'." >&2; exit 1; }
done

cfg() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }

_resolve_project() {
  local remote; remote="$(cfg '.remote')"; [ "$remote" = "null" ] && remote="origin"
  local url; url="$(git remote get-url "$remote" 2>/dev/null || true)"
  [ -n "$url" ] || { echo "ERROR: remote '$remote' no encontrado." >&2; exit 1; }
  url="${url%.git}"
  case "$url" in
    git@*:*)            HOST="${url#git@}"; HOST="${HOST%%:*}"; PROJECT_PATH="${url#*:}" ;;
    ssh://*)            local r="${url#ssh://}"; r="${r#*@}"; HOST="${r%%/*}"; HOST="${HOST%%:*}"; PROJECT_PATH="${r#*/}" ;;
    https://*|http://*) local r="${url#*://}"; r="${r#*@}"; HOST="${r%%/*}"; PROJECT_PATH="${r#*/}" ;;
    *)                  HOST=""; PROJECT_PATH="$url" ;;
  esac
  ENC_PATH="${PROJECT_PATH//\//%2F}"
  [ -n "$HOST" ] && export GITLAB_HOST="$HOST"
}
_resolve_project

api() { glab api "$@"; }

# Resuelve el id numérico de un milestone por su título (necesario para milestone_id).
milestone_id_by_title() {
  local title="$1"
  api "projects/$ENC_PATH/milestones?per_page=100" \
    | jq -r --arg t "$title" '[.[]|select(.title==$t)]|first|.id // empty'
}

confirm() {
  # Respeta GLAB_PM_YES=1 para modo no interactivo.
  [ "${GLAB_PM_YES:-0}" = "1" ] && return 0
  read -r -p "$1 [y/N] " ans
  case "$ans" in y|Y|yes|si|sí) return 0 ;; *) echo "Cancelado."; return 1 ;; esac
}

# ---------------------------------------------------------------------------
cmd_doctor() {
  echo "Host:        ${HOST:-?}"
  echo "Proyecto:    $PROJECT_PATH"
  glab auth status 2>&1 | sed 's/^/  /' || true
  local p; p="$(api "projects/$ENC_PATH" 2>/dev/null || echo '{}')"
  echo "Project ID:  $(echo "$p" | jq -r '.id // "INACCESIBLE"')"
  echo "Default:     $(echo "$p" | jq -r '.default_branch // "?"')"
  echo "Issues:      $(echo "$p" | jq -r '.issues_enabled // "?"')"
  echo "Access lvl:  $(echo "$p" | jq -r '.permissions.project_access.access_level // "?"')"
}

cmd_topology() { "$SCRIPT_DIR/repo-topology.sh" "$@"; }

# Crea las labels definidas en config.json (idempotente).
cmd_bootstrap_labels() {
  local names; names="$(cfg '.labels | keys[]')"
  for name in $names; do
    local color desc
    color="$(cfg ".labels.\"$name\".color")"
    desc="$(cfg ".labels.\"$name\".description")"
    glab label create --name "$name" --color "$color" --description "$desc" 2>/dev/null \
      && echo "  + $name" || echo "  = $name (ya existe)"
  done
}

# Asegura issues habilitadas, default branch = integration, y protección de main/develop.
cmd_ensure_branch_model() {
  local integ rel; integ="$(cfg '.branch_model.integration')"; rel="$(cfg '.branch_model.release')"
  echo "Modelo: integración=$integ release=$rel"
  confirm "¿Aplicar configuración (enable issues, default=$integ, proteger $rel y $integ)?" || return 1

  api "projects/$ENC_PATH" -X PUT -f issues_access_level=enabled >/dev/null && echo "  issues: enabled"

  # Crear develop desde release si no existe
  if ! api "projects/$ENC_PATH/repository/branches/$integ" >/dev/null 2>&1; then
    api "projects/$ENC_PATH/repository/branches" -f branch="$integ" -f ref="$rel" >/dev/null \
      && echo "  rama $integ creada desde $rel"
  fi
  api "projects/$ENC_PATH" -X PUT -f default_branch="$integ" >/dev/null && echo "  default_branch: $integ"

  # Proteger: push=No one(0), merge=Maintainer(40)
  for b in "$rel" "$integ"; do
    api "projects/$ENC_PATH/protected_branches/$b" -X DELETE >/dev/null 2>&1 || true
    api "projects/$ENC_PATH/protected_branches" -f name="$b" -F push_access_level=0 -F merge_access_level=40 >/dev/null \
      && echo "  protegida: $b (push=none, merge=maintainer)"
  done
  echo "NOTA: 'a $rel solo desde $integ' NO es nativo en GitLab; usa el guard CI (assets/ci-guard.yml)."
}

cmd_sprint_new() {
  local title="${1:?Uso: sprint-new <titulo> [due YYYY-MM-DD] [desc]}"; local due="${2:-}"; local desc="${3:-}"
  local args=(-f title="$title"); [ -n "$due" ] && args+=(-f due_date="$due"); [ -n "$desc" ] && args+=(-f description="$desc")
  api "projects/$ENC_PATH/milestones" -X POST "${args[@]}" \
    | jq -r '"Milestone #\(.iid) creado: \(.title) (id \(.id), due \(.due_date // "-"))"'
}

cmd_sprint_list() {
  api "projects/$ENC_PATH/milestones?per_page=100" \
    | jq -r '.[] | "#\(.iid) [\(.state)] \(.title)  due=\(.due_date // "-")  id=\(.id)"'
}

cmd_issue_new() {
  local title="${1:?Uso: issue-new <titulo> <label> <milestone-title> [desc]}"
  local label="${2:?falta label}"; local ms_title="${3:?falta milestone}"; local desc="${4:-}"
  local mid; mid="$(milestone_id_by_title "$ms_title")"
  [ -n "$mid" ] || { echo "ERROR: milestone '$ms_title' no existe (usa sprint-new)." >&2; exit 1; }
  api "projects/$ENC_PATH/issues" -X POST -f title="$title" -f labels="$label" -F milestone_id="$mid" -f description="$desc" \
    | jq -r '"Issue #\(.iid) creada: \(.title)  [\(.labels|join(","))]  \(.web_url)"'
}

cmd_issue_list() {
  local ms="${1:-}"; local state="${2:-opened}"
  local q="projects/$ENC_PATH/issues?state=$state&per_page=100"
  [ -n "$ms" ] && q="$q&milestone=$(printf '%s' "$ms" | jq -sRr @uri)"
  api "$q" | jq -r '
    if length==0 then "(sin issues)"
    else .[] | "#\(.iid) [\(.state)] [\(.labels|join(","))] \(.title)" end'
}

# Sugiere/crea rama desde la base de integración para una issue.
cmd_branch_for() {
  local iid="${1:?Uso: branch-for <issue-iid> <label>}"; local label="${2:?falta label}"
  local prefix base slug title
  prefix="$(cfg ".labels.\"$label\".branch_prefix")"; [ "$prefix" = "null" ] && prefix="$label"
  base="$(cfg '.branch_model.feature_branches_base')"
  title="$(api "projects/$ENC_PATH/issues/$iid" | jq -r '.title')"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
  local branch="$prefix/$iid-$slug"
  echo "Rama sugerida: $branch (base: $base)"
  if confirm "¿Crear y checkout '$branch' desde origin/$base?"; then
    git fetch origin --quiet
    git checkout -b "$branch" "origin/$base" && echo "OK: en $branch"
  fi
}

cmd_mr_new() {
  # mr-new <source> <target> <title> <label> <milestone-title> [closes-iid] [desc]
  local src="${1:?source}"; local tgt="${2:?target}"; local title="${3:?title}"
  local label="${4:?label}"; local ms="${5:?milestone}"; local closes="${6:-}"; local desc="${7:-}"
  [ -n "$closes" ] && desc="${desc}

Closes #${closes}"
  glab mr create --source-branch "$src" --target-branch "$tgt" \
    --title "$title" --description "$desc" \
    --milestone "$ms" --label "$label" --remove-source-branch --yes
}

# Espera a que el último pipeline del MR termine; imprime estado final.
cmd_pipeline_watch() {
  local mr_iid="${1:?Uso: pipeline-watch <mr-iid>}"
  local interval max; interval="$(cfg '.pipeline.poll_interval_seconds')"; max="$(cfg '.pipeline.poll_max_minutes')"
  [ "$interval" = "null" ] && interval=15; [ "$max" = "null" ] && max=20
  local pid; pid="$(api "projects/$ENC_PATH/merge_requests/$mr_iid/pipelines" | jq -r '.[0].id // empty')"
  [ -n "$pid" ] || { echo "Sin pipeline para MR !$mr_iid."; return 0; }
  echo "Pipeline $pid (MR !$mr_iid)..."
  local elapsed=0 st
  while [ "$elapsed" -lt "$((max*60))" ]; do
    st="$(api "projects/$ENC_PATH/pipelines/$pid" | jq -r '.status')"
    echo "  [${elapsed}s] $st"
    case "$st" in success) return 0 ;; failed|canceled) return 2 ;; esac
    sleep "$interval"; elapsed=$((elapsed+interval))
  done
  echo "TIMEOUT tras ${max}m (estado: ${st:-?})."; return 3
}

# Mergea un MR; por defecto exige pipeline verde si lo pide config.
cmd_mr_merge() {
  local mr_iid="${1:?Uso: mr-merge <mr-iid> [--no-wait]}"; local wait_flag="${2:-}"
  local require; require="$(cfg '.pipeline.require_green_before_merge')"
  if [ "$require" = "true" ] && [ "$wait_flag" != "--no-wait" ]; then
    cmd_pipeline_watch "$mr_iid" || { echo "ERROR: pipeline no verde; no se mergea." >&2; return 2; }
  fi
  local tgt; tgt="$(api "projects/$ENC_PATH/merge_requests/$mr_iid" | jq -r '.target_branch')"
  confirm "¿Mergear MR !$mr_iid en '$tgt'?" || return 1
  glab mr merge "$mr_iid" --yes --remove-source-branch
}

# Release: tag en ref (default main). Avisa del auto-close de milestone.
cmd_release() {
  local tag="${1:?Uso: release <tag> [ref] [notes-file] [milestone-title]}"
  local ref="${2:-$(cfg '.release.ref')}"; [ "$ref" = "null" ] && ref="main"
  local notes_file="${3:-}"; local ms="${4:-}"
  local args=(--ref "$ref" --name "$tag")
  [ -n "$notes_file" ] && args+=(--notes-file "$notes_file")
  if [ -n "$ms" ]; then
    echo "AVISO: 'glab release --milestone' CIERRA el milestone. Si la release es parcial, reábrelo después." >&2
    args+=(--milestone "$ms")
  fi
  confirm "¿Crear release/tag '$tag' sobre '$ref'?" || return 1
  glab release create "$tag" "${args[@]}"
}

cmd_summary() {
  local ms="${1:-}"
  local q="projects/$ENC_PATH/issues?per_page=100&state=all"
  [ -n "$ms" ] && q="$q&milestone=$(printf '%s' "$ms" | jq -sRr @uri)"
  api "$q" | jq -r --arg ms "$ms" '
    (length) as $t | ([.[]|select(.state=="closed")]|length) as $c |
    (if $ms!="" then "Sprint: \($ms)" else "Proyecto (todas las issues)" end),
    "Issues: \($c)/\($t) cerradas (\(if $t>0 then ($c*100/$t|floor) else 0 end)%)",
    "Abiertas por label:",
    ([.[]|select(.state=="opened")] | group_by(.labels[0]? // "sin-label")[] |
      "  \((.[0].labels[0]? // "sin-label")): \(length)"),
    "Abiertas:",
    ([.[]|select(.state=="opened")] | if length==0 then "  (ninguna)" else .[]|"  #\(.iid) \(.title)" end)'
}

cmd_help() {
  cat <<'EOF'
glab-pm.sh — Project Management para GitLab (genérico, autodetecta el repo)

  doctor                          Diagnóstico: auth, proyecto, permisos
  topology [--json]               Topología git+GitLab (delega en repo-topology.sh)
  bootstrap-labels                Crear labels de config.json (idempotente)
  ensure-branch-model             Enable issues + default=develop + proteger main/develop  [confirma]
  sprint-new <titulo> [due] [desc]            Crear milestone
  sprint-list                                 Listar milestones
  issue-new <titulo> <label> <milestone> [desc]   Crear issue en milestone
  issue-list [milestone] [state]              Listar issues
  branch-for <issue-iid> <label>              Sugerir/crear rama desde develop  [confirma]
  mr-new <src> <tgt> <titulo> <label> <milestone> [closes-iid] [desc]   Crear MR
  pipeline-watch <mr-iid>                     Esperar al pipeline del MR
  mr-merge <mr-iid> [--no-wait]               Mergear (exige pipeline verde)  [confirma]
  release <tag> [ref] [notes-file] [milestone]   Crear release/tag  [confirma]
  summary [milestone]                         Reporte de progreso

Variables: GLAB_PM_YES=1 salta confirmaciones (modo no interactivo).
EOF
}

case "${1:-help}" in
  doctor)             cmd_doctor "${@:2}" ;;
  topology)           cmd_topology "${@:2}" ;;
  bootstrap-labels)   cmd_bootstrap_labels "${@:2}" ;;
  ensure-branch-model) cmd_ensure_branch_model "${@:2}" ;;
  sprint-new)         cmd_sprint_new "${@:2}" ;;
  sprint-list)        cmd_sprint_list "${@:2}" ;;
  issue-new)          cmd_issue_new "${@:2}" ;;
  issue-list)         cmd_issue_list "${@:2}" ;;
  branch-for)         cmd_branch_for "${@:2}" ;;
  mr-new)             cmd_mr_new "${@:2}" ;;
  pipeline-watch)     cmd_pipeline_watch "${@:2}" ;;
  mr-merge)           cmd_mr_merge "${@:2}" ;;
  release)            cmd_release "${@:2}" ;;
  summary)            cmd_summary "${@:2}" ;;
  help|-h|--help)     cmd_help ;;
  *)                  echo "Comando desconocido: $1" >&2; cmd_help; exit 1 ;;
esac
