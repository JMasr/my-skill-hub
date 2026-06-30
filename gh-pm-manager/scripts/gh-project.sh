#!/usr/bin/env bash
# gh-project.sh — Wrapper para GitHub Projects v2 (GraphQL)
# Uso: ./gh-project.sh <comando> [argumentos]
# Comandos: init, add, set, list, summary, sync
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.json"

# --- Helpers ---

cfg() { jq -r "$1" "$CONFIG_FILE"; }

cfg_write() {
  local tmp
  tmp=$(mktemp)
  jq "$@" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

gql() {
  local query="$1"; shift
  gh api graphql -f query="$query" "$@"
}

check_deps() {
  local ok=true
  if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI no encontrado. Instalar: https://cli.github.com" >&2; ok=false
  fi
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq no encontrado. Instalar: sudo apt install jq / brew install jq" >&2; ok=false
  fi
  if ! gh auth status &>/dev/null; then
    echo "ERROR: gh no autenticado. Ejecutar: gh auth login" >&2; ok=false
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.json no encontrado en $CONFIG_FILE" >&2; ok=false
  fi
  $ok || exit 1
}

check_project() {
  local pid
  pid=$(cfg '.project.id')
  if [ "$pid" = "null" ] || [ -z "$pid" ]; then
    echo "ERROR: Proyecto no inicializado. Ejecutar: $0 init" >&2
    exit 1
  fi
}

# --- Comandos ---

cmd_init() {
  echo "=== Inicializando proyecto GitHub Projects v2 ==="

  local title
  title=$(cfg '.project.title')

  # Obtener node ID del usuario
  local viewer_data
  viewer_data=$(gql 'query { viewer { id login } }')
  local user_id
  user_id=$(echo "$viewer_data" | jq -r '.data.viewer.id')
  local user_login
  user_login=$(echo "$viewer_data" | jq -r '.data.viewer.login')
  echo "Usuario: $user_login"

  local project_id project_number
  local existing_id
  existing_id=$(cfg '.project.id')

  if [ "$existing_id" != "null" ] && [ -n "$existing_id" ]; then
    # Proyecto ya existe — usar el ID guardado
    project_id="$existing_id"
    project_number=$(cfg '.project.number')
    echo "Proyecto ya existe: #$project_number (ID: $project_id) — saltando creación"
  else
    # Crear proyecto
    echo "Creando proyecto: $title"
    local project_data
    project_data=$(gql '
      mutation($ownerId: ID!, $title: String!) {
        createProjectV2(input: {ownerId: $ownerId, title: $title}) {
          projectV2 { id number }
        }
      }' -f ownerId="$user_id" -f title="$title")

    project_id=$(echo "$project_data" | jq -r '.data.createProjectV2.projectV2.id')
    project_number=$(echo "$project_data" | jq -r '.data.createProjectV2.projectV2.number')
    echo "Proyecto creado: #$project_number (ID: $project_id)"

    cfg_write --arg id "$project_id" --argjson num "$project_number" \
      '.project.id = $id | .project.number = $num'
  fi

  # Obtener campo Status por defecto y sus opciones (siempre re-leer para mantener sync)
  echo "Leyendo campo Status existente..."
  local fields_data
  fields_data=$(gql '
    query($pid: ID!) {
      node(id: $pid) {
        ... on ProjectV2 {
          fields(first: 20) {
            nodes {
              ... on ProjectV2SingleSelectField {
                id name options { id name }
              }
            }
          }
        }
      }
    }' -f pid="$project_id")

  local status_field
  status_field=$(echo "$fields_data" | jq '[.data.node.fields.nodes[] | select(.name == "Status")] | first')
  local status_id
  status_id=$(echo "$status_field" | jq -r '.id')
  local status_options
  status_options=$(echo "$status_field" | jq '[.options[] | {(.name): .id}] | add')

  cfg_write --arg sid "$status_id" --argjson opts "$status_options" \
    '.fields.status = {id: $sid, options: $opts}'
  echo "  Status: OK"

  # Crear campos custom (saltados si ya existen en config)
  create_select_field "$project_id" "Prioridad" \
    '[{name:"Alta",color:RED,description:""},{name:"Media",color:YELLOW,description:""},{name:"Baja",color:GREEN,description:""}]' \
    "prioridad"

  create_select_field "$project_id" "Estimacion" \
    '[{name:"XS",color:GRAY,description:""},{name:"S",color:BLUE,description:""},{name:"M",color:GREEN,description:""},{name:"L",color:YELLOW,description:""},{name:"XL",color:RED,description:""}]' \
    "estimacion"

  create_select_field "$project_id" "Tipo" \
    '[{name:"feature",color:GREEN,description:""},{name:"bug",color:RED,description:""},{name:"chore",color:GRAY,description:""},{name:"tech-debt",color:ORANGE,description:""},{name:"docs",color:BLUE,description:""},{name:"discovery",color:PURPLE,description:""}]' \
    "tipo"

  create_select_field "$project_id" "Sprint" \
    '[{name:"Sprint 1",color:BLUE,description:""},{name:"Sprint 2",color:GREEN,description:""},{name:"Sprint 3",color:YELLOW,description:""},{name:"Sprint 4",color:ORANGE,description:""},{name:"Sprint 5",color:RED,description:""}]' \
    "sprint"

  # Crear labels en cada repo (sync, tipo y gestión)
  echo "Creando labels..."
  local owner
  owner=$(cfg '.owner')
  for repo in $(jq -r '.repos[]' "$CONFIG_FILE"); do
    # Labels de sincronización
    gh label create "sync:frontend"  --repo "$owner/$repo" --color "1D76DB" --description "Requiere sync en frontend" 2>/dev/null || true
    gh label create "sync:backend"   --repo "$owner/$repo" --color "D93F0B" --description "Requiere sync en backend" 2>/dev/null || true
    gh label create "sync:infra"     --repo "$owner/$repo" --color "7057FF" --description "Requiere sync en infra" 2>/dev/null || true
    # Labels de gestión
    gh label create "epic"           --repo "$owner/$repo" --color "3E4B9E" --description "Issue épica/coordinadora" 2>/dev/null || true
    gh label create "discovery"      --repo "$owner/$repo" --color "BFDADC" --description "Investigación/descubrimiento" 2>/dev/null || true
    # Labels de tipo
    gh label create "feature"        --repo "$owner/$repo" --color "0E8A16" --description "Nueva funcionalidad" 2>/dev/null || true
    gh label create "bug"            --repo "$owner/$repo" --color "D73A4A" --description "Error o defecto" 2>/dev/null || true
    gh label create "chore"          --repo "$owner/$repo" --color "EDEDED" --description "Tarea de mantenimiento" 2>/dev/null || true
    gh label create "tech-debt"      --repo "$owner/$repo" --color "FFA500" --description "Deuda técnica" 2>/dev/null || true
    gh label create "docs"           --repo "$owner/$repo" --color "0075CA" --description "Documentación" 2>/dev/null || true
    gh label create "infra"          --repo "$owner/$repo" --color "7057FF" --description "Infraestructura" 2>/dev/null || true
  done
  echo "  Labels: OK"

  echo ""
  echo "=== Proyecto inicializado correctamente ==="
  echo "URL: https://github.com/users/$user_login/projects/$project_number"
}

create_select_field() {
  local project_id="$1" name="$2" options_gql="$3" config_key="$4"

  # Si el campo ya existe en config, no recrear
  local existing_fid
  existing_fid=$(cfg ".fields.\"$config_key\".id // \"null\"")
  if [ "$existing_fid" != "null" ] && [ -n "$existing_fid" ]; then
    echo "  $name: ya existe (saltando)"
    return 0
  fi

  echo "Creando campo: $name"
  # GraphQL no acepta variables para singleSelectOptions, se inyecta directo
  local mutation
  mutation="mutation {
    createProjectV2Field(input: {
      projectId: \"$project_id\"
      dataType: SINGLE_SELECT
      name: \"$name\"
      singleSelectOptions: $options_gql
    }) {
      projectV2Field {
        ... on ProjectV2SingleSelectField {
          id options { id name }
        }
      }
    }
  }"

  local result
  result=$(gql "$mutation")
  local field_id
  field_id=$(echo "$result" | jq -r '.data.createProjectV2Field.projectV2Field.id')
  local field_options
  field_options=$(echo "$result" | jq '[.data.createProjectV2Field.projectV2Field.options[] | {(.name): .id}] | add')

  cfg_write --arg fid "$field_id" --argjson opts "$field_options" --arg key "$config_key" \
    '.fields[$key] = {id: $fid, options: $opts}'
  echo "  $name: OK"
}

cmd_add() {
  if [ $# -lt 2 ]; then
    echo "Uso: $0 add <repo-name> <issue-number>" >&2
    exit 1
  fi
  check_project

  local repo="$1" issue_num="$2"
  local owner
  owner=$(cfg '.owner')
  local project_id
  project_id=$(cfg '.project.id')

  # Obtener node ID del issue
  local issue_id
  issue_id=$(gql '
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) { id title }
      }
    }' -f owner="$owner" -f repo="$repo" -F number="$issue_num" \
    --jq '.data.repository.issue.id')

  # Añadir al proyecto
  local item_id
  item_id=$(gql '
    mutation($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }' -f projectId="$project_id" -f contentId="$issue_id" \
    --jq '.data.addProjectV2ItemById.item.id')

  echo "$item_id"
}

cmd_set() {
  if [ $# -lt 3 ]; then
    echo "Uso: $0 set <item-id> <campo> <valor>" >&2
    echo "Campos: status, prioridad, estimacion, tipo, sprint" >&2
    exit 1
  fi
  check_project

  local item_id="$1" field_name="$2" value="$3"
  local project_id
  project_id=$(cfg '.project.id')
  local field_id
  field_id=$(cfg ".fields.\"$field_name\".id")
  local option_id
  option_id=$(cfg ".fields.\"$field_name\".options.\"$value\"")

  if [ "$field_id" = "null" ] || [ "$option_id" = "null" ]; then
    echo "ERROR: Campo '$field_name' o valor '$value' no encontrado en config." >&2
    echo "Campos disponibles: $(jq -r '.fields | keys[]' "$CONFIG_FILE")" >&2
    exit 1
  fi

  gql '
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: {singleSelectOptionId: $optionId}
      }) {
        projectV2Item { id }
      }
    }' -f projectId="$project_id" -f itemId="$item_id" \
       -f fieldId="$field_id" -f optionId="$option_id" > /dev/null

  echo "OK: $field_name=$value en item $item_id"
}

cmd_list() {
  check_project

  local filter="${1:-all}"
  local project_id
  project_id=$(cfg '.project.id')

  local raw
  raw=$(gql '
    query($pid: ID!) {
      node(id: $pid) {
        ... on ProjectV2 {
          items(first: 100) {
            nodes {
              id
              fieldValues(first: 10) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field { ... on ProjectV2SingleSelectField { name } }
                  }
                }
              }
              content {
                ... on Issue {
                  title number state url
                  repository { name }
                  labels(first: 10) { nodes { name } }
                }
              }
            }
          }
        }
      }
    }' -f pid="$project_id")

  # Transformar a formato legible con jq
  local items
  items=$(echo "$raw" | jq -r '
    [.data.node.items.nodes[] | select(.content != null) | {
      id: .id,
      number: .content.number,
      title: .content.title,
      repo: .content.repository.name,
      state: .content.state,
      url: .content.url,
      labels: [.content.labels.nodes[].name] | join(","),
      fields: ([.fieldValues.nodes[] | select(.field != null) |
                {(.field.name): .name}] | add // {})
    }]')

  # Aplicar filtro
  case "$filter" in
    all)
      ;;
    repo:*)
      local repo_filter="${filter#repo:}"
      items=$(echo "$items" | jq --arg r "$repo_filter" '[.[] | select(.repo == $r)]')
      ;;
    status:*)
      local status_filter="${filter#status:}"
      items=$(echo "$items" | jq --arg s "$status_filter" '[.[] | select(.fields.Status == $s)]')
      ;;
    prioridad:*)
      local prio_filter="${filter#prioridad:}"
      items=$(echo "$items" | jq --arg p "$prio_filter" '[.[] | select(.fields.Prioridad == $p)]')
      ;;
    sprint:*)
      local sprint_filter="${filter#sprint:}"
      items=$(echo "$items" | jq --arg s "$sprint_filter" '[.[] | select(.fields.Sprint == $s)]')
      ;;
    label:*)
      local label_filter="${filter#label:}"
      items=$(echo "$items" | jq --arg l "$label_filter" '[.[] | select(.labels | split(",") | any(. == $l))]')
      ;;
    *)
      echo "Filtro no reconocido: $filter" >&2
      echo "Filtros: all | repo:<nombre> | status:<valor> | prioridad:<valor> | sprint:<valor> | label:<nombre>" >&2
      exit 1
      ;;
  esac

  # Imprimir tabla
  echo "$items" | jq -r '
    if length == 0 then "No hay items con ese filtro."
    else
      (.[] | "#\(.number)\t[\(.repo)]\t\(.title)\t| \(.fields.Status // "-")\t| \(.fields.Prioridad // "-")\t| \(.fields.Estimacion // "-")\t| \(.fields.Sprint // "-")")
    end'
}

cmd_summary() {
  check_project

  local sprint_filter="${1:-}"
  local project_id
  project_id=$(cfg '.project.id')
  local title
  title=$(cfg '.project.title')

  local raw
  raw=$(gql '
    query($pid: ID!) {
      node(id: $pid) {
        ... on ProjectV2 {
          items(first: 100) {
            nodes {
              fieldValues(first: 10) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field { ... on ProjectV2SingleSelectField { name } }
                  }
                }
              }
              content {
                ... on Issue {
                  title number state
                  repository { name }
                  labels(first: 10) { nodes { name } }
                }
              }
            }
          }
        }
      }
    }' -f pid="$project_id")

  # Generar resumen con jq
  echo "$raw" | jq -r --arg title "$title" --arg sf "$sprint_filter" '
    def items: [.data.node.items.nodes[] | select(.content != null) | {
      repo: .content.repository.name,
      state: .content.state,
      number: .content.number,
      title: .content.title,
      labels: [.content.labels.nodes[].name],
      status: ([.fieldValues.nodes[] | select(.field.name == "Status")] | first | .name // "Sin status"),
      prioridad: ([.fieldValues.nodes[] | select(.field.name == "Prioridad")] | first | .name // "-"),
      sprint: ([.fieldValues.nodes[] | select(.field.name == "Sprint")] | first | .name // "-")
    }];
    items as $raw |
    (if $sf != "" then [$raw[] | select(.sprint == $sf)] else $raw end) as $all |
    ($all | length) as $total |
    ([$all[] | select(.status == "Done")] | length) as $done |
    (if $sf != "" then "📊 Estado: \($title) — \($sf)" else "📊 Estado: \($title)" end),
    "Total: \($total) items | Completados: \($done) (\(if $total > 0 then ($done * 100 / $total | floor) else 0 end)%)",
    "",
    "Por repo:",
    ($all | group_by(.repo)[] |
      (first.repo) as $r |
      (length) as $t |
      ([.[] | select(.status == "Done")] | length) as $d |
      "  \($r): \($d)/\($t) completados"),
    "",
    "Prioridad Alta pendientes:",
    ([$all[] | select(.prioridad == "Alta" and .status != "Done")] |
      if length == 0 then "  (ninguno)"
      else .[] | "  - #\(.number) \(.title) [\(.repo)] — \(.status)"
      end),
    "",
    "Pendientes de sync:",
    ([$all[] | select(.labels | any(startswith("sync:"))) | select(.status != "Done")] |
      if length == 0 then "  (ninguno)"
      else .[] | "  - #\(.number) \(.title) [\(.repo)] — \(.labels | map(select(startswith("sync:"))) | join(", "))"
      end)
  '
}

cmd_sync() {
  if [ $# -lt 2 ]; then
    echo "Uso: $0 sync <repo-origen> <repo-destino>" >&2
    echo "Ejemplo: $0 sync kernel-backend frontend" >&2
    echo "  (lista issues cerrados en kernel-backend con label sync:frontend)" >&2
    exit 1
  fi

  local source_repo="$1" target="$2"
  local owner
  owner=$(cfg '.owner')
  local sync_label="sync:${target}"

  echo "=== Issues en $source_repo pendientes de sync con $target ==="
  echo ""

  # Issues cerrados con el label de sync
  gh issue list -R "$owner/$source_repo" --state closed --label "$sync_label" \
    --json number,title,url,labels,body --jq '
      if length == 0 then "No hay issues de sync pendientes."
      else .[] | "#\(.number)\t\(.title)\n  \(.url)"
      end'

  echo ""
  echo "--- Issues abiertos con sync pendiente ---"
  gh issue list -R "$owner/$source_repo" --state open --label "$sync_label" \
    --json number,title,url --jq '
      if length == 0 then "No hay issues abiertos con sync pendiente."
      else .[] | "#\(.number)\t\(.title)\n  \(.url)"
      end'
}

cmd_add_option() {
  if [ $# -lt 2 ]; then
    echo "Uso: $0 add-option <campo> <nombre-opcion> [color]" >&2
    echo "Colores: GRAY BLUE GREEN YELLOW ORANGE RED PINK PURPLE" >&2
    echo "Ejemplo: $0 add-option sprint 'Sprint 6' BLUE" >&2
    exit 1
  fi
  check_project

  local field_name="$1" option_name="$2" option_color="${3:-BLUE}"
  local project_id
  project_id=$(cfg '.project.id')
  local field_id
  field_id=$(cfg ".fields.\"$field_name\".id")

  if [ "$field_id" = "null" ] || [ -z "$field_id" ]; then
    echo "ERROR: Campo '$field_name' no encontrado en config." >&2
    exit 1
  fi

  # Query existing options with IDs and colors from GitHub (source of verdad)
  local field_data
  field_data=$(gql '
    query($pid: ID!) {
      node(id: $pid) {
        ... on ProjectV2 {
          fields(first: 20) {
            nodes {
              ... on ProjectV2SingleSelectField {
                id name options { id name color description }
              }
            }
          }
        }
      }
    }' -f pid="$project_id")

  # Build options GQL: existing (with id to preserve) + new (without id)
  local options_gql
  options_gql=$(echo "$field_data" | jq -r --arg fid "$field_id" \
    --arg new_name "$option_name" --arg new_color "$option_color" '
    [.data.node.fields.nodes[] | select(.id == $fid)] | first |
    [
      (.options[] | "{id:\"\(.id)\",name:\"\(.name)\",color:\(.color),description:\"\(.description // "")\"}"),
      "{name:\"\($new_name)\",color:\($new_color),description:\"\"}"
    ] | join(",")')

  # Update field with all options (existing preserved by ID + new)
  # Note: updateProjectV2Field does NOT accept projectId — only fieldId
  local mutation
  mutation="mutation {
    updateProjectV2Field(input: {
      fieldId: \"$field_id\"
      singleSelectOptions: [$options_gql]
    }) {
      projectV2Field {
        ... on ProjectV2SingleSelectField {
          id options { id name }
        }
      }
    }
  }"

  local result
  result=$(gql "$mutation")

  # Verificar que la mutación no devolvió errores antes de tocar config
  local api_errors
  api_errors=$(echo "$result" | jq -r '.errors // empty')
  if [ -n "$api_errors" ]; then
    echo "ERROR: la API devolvió errores al actualizar el campo:" >&2
    echo "$api_errors" >&2
    exit 1
  fi

  # Refresh config with updated option IDs
  local updated_opts
  updated_opts=$(echo "$result" | jq '[.data.updateProjectV2Field.projectV2Field.options[] | {(.name): .id}] | add')

  if [ "$updated_opts" = "null" ] || [ -z "$updated_opts" ]; then
    echo "ERROR: la respuesta no contiene opciones actualizadas. Config no modificado." >&2
    exit 1
  fi

  cfg_write --argjson opts "$updated_opts" --arg key "$field_name" \
    '.fields[$key].options = $opts'

  echo "OK: '$option_name' añadida al campo '$field_name'"
}

cmd_help() {
  cat <<'EOF'
gh-project.sh — Gestión de GitHub Projects v2

Comandos:
  init                                Crear proyecto, campos custom y labels
  add <repo> <issue-num>              Añadir issue al proyecto (devuelve ITEM_ID)
  set <item-id> <campo> <valor>       Actualizar campo de un item
  list [filtro]                       Listar items del proyecto
  summary [sprint]                    Resumen de progreso
  sync <repo-src> <repo-dest>         Issues con sync pendiente entre repos
  add-option <campo> <nombre> [color] Añadir opción a un campo single-select
  help                                Mostrar esta ayuda

Campos para 'set': status, prioridad, estimacion, tipo, sprint

Filtros para 'list':
  all | repo:<nombre> | status:<valor> | prioridad:<valor>
  sprint:<valor> | label:<nombre>

Colores para 'add-option':
  GRAY BLUE GREEN YELLOW ORANGE RED PINK PURPLE
EOF
}

# --- Main ---

check_deps

case "${1:-help}" in
  init)       cmd_init "${@:2}" ;;
  add)        cmd_add "${@:2}" ;;
  set)        cmd_set "${@:2}" ;;
  list)       cmd_list "${@:2}" ;;
  summary)    cmd_summary "${@:2}" ;;
  sync)       cmd_sync "${@:2}" ;;
  add-option) cmd_add_option "${@:2}" ;;
  help)       cmd_help ;;
  *)          echo "Comando desconocido: $1" >&2; cmd_help; exit 1 ;;
esac
