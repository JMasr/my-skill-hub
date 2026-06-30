# gh-pm-manager — Skill de Project Management para Claude Code

Gestión centralizada de proyectos multi-repo SaaS en GitHub Projects v2.
Claude Code actúa como Project Manager: crea issues, prioriza, estima y
reporta progreso sin tocar código.

## Requisitos

- [GitHub CLI](https://cli.github.com) (`gh`) autenticado
- `jq` para procesamiento JSON
- Claude Code con soporte de skills

## Instalación

```bash
# 1. Copiar al directorio de skills de Claude Code
cp -r gh-pm-manager ~/.claude/skills/gh-pm-manager

# 2. Dar permisos al script
chmod +x ~/.claude/skills/gh-pm-manager/scripts/gh-project.sh

# 3. Editar config.json con tu usuario y repos
# (por defecto: JMasr/kernel-{frontend,backend,infra})

# 4. Inicializar el proyecto (primera vez)
~/.claude/skills/gh-pm-manager/scripts/gh-project.sh init
```

## Comandos del script

| Comando | Descripción |
|---------|-------------|
| `init` | Crear proyecto, campos custom y labels |
| `add <repo> <issue>` | Añadir issue al proyecto |
| `set <item> <campo> <valor>` | Actualizar campo de un item |
| `list [filtro]` | Listar items (filtros: repo, status, prioridad, sprint, label) |
| `summary [sprint]` | Resumen de progreso |
| `sync <origen> <destino>` | Issues pendientes de sincronización |

## Estructura

```
gh-pm-manager/
├── SKILL.md              # Instrucciones de comportamiento para Claude Code
├── config.json           # Configuración del proyecto (repos, IDs, campos)
├── scripts/
│   └── gh-project.sh     # Wrapper GraphQL para GitHub Projects v2
└── README.md
```

## Campos del proyecto

- **Status**: Todo, In Progress, Done (default de GitHub)
- **Prioridad**: Alta, Media, Baja
- **Estimación**: XS, S, M, L, XL
- **Tipo**: feature, bug, chore, tech-debt, docs, discovery
- **Sprint**: Sprint 1 — Sprint 5

## Licencia

Uso interno. Adaptar libremente.
