# gl-pm-manager — Skill de Project Management para GitLab

Project Manager de sprints en **GitLab** vía `glab` CLI, pensada para que cualquier
agente de código basado en IA gestione Issues, milestones, labels, Merge Requests,
pipelines y releases con un flujo GitFlow trazable y mensajes de registro
consistentes (commits/MR/release claros y sin firma de autoría).

Es el equivalente GitLab de la skill `gh-pm-manager` (que cubre GitHub Projects v2).

## Requisitos

- [`glab`](https://gitlab.com/gitlab-org/cli) autenticado contra tu host de GitLab
- `jq`
- `git` (los scripts autodetectan el proyecto desde el remote)
- Agente con soporte de skills (p. ej. Claude Code)

## Instalación

```bash
cp -r gl-pm-manager ~/.claude/skills/gl-pm-manager
chmod +x ~/.claude/skills/gl-pm-manager/scripts/*.sh
# (opcional) ajusta convenciones en config.json
```

No hace falta configurar owner/repo: se detecta desde el remote git del repo donde
trabajes. `config.json` solo define convenciones (labels, modelo de ramas, estilo
de mensajes, política de pipeline).

## Scripts

### `scripts/repo-topology.sh` — captura de topología
Vuelca el estado git + GitLab del repo antes de actuar.

```bash
repo-topology.sh           # reporte legible
repo-topology.sh --json    # JSON para consumo programático
```
Incluye: host/proyecto, default branch, issues habilitadas, protected branches,
labels, milestones, Issues/MRs abiertos, runners disponibles y pipelines recientes.

### `scripts/glab-pm.sh` — operaciones

| Comando | Descripción |
|---|---|
| `doctor` | Diagnóstico (auth, proyecto, permisos) |
| `topology [--json]` | Delega en repo-topology.sh |
| `bootstrap-labels` | Crea las labels de config.json (idempotente) |
| `ensure-branch-model` | Enable issues + default=develop + protege main/develop |
| `sprint-new <titulo> [due] [desc]` | Crea milestone (sprint) |
| `sprint-list` | Lista milestones |
| `issue-new <titulo> <label> <milestone> [desc]` | Crea Issue en el milestone |
| `issue-list [milestone] [state]` | Lista Issues |
| `branch-for <issue-iid> <label>` | Crea rama desde develop |
| `mr-new <src> <tgt> <titulo> <label> <milestone> [closes] [desc]` | Crea MR |
| `pipeline-watch <mr-iid>` | Espera al pipeline del MR |
| `mr-merge <mr-iid> [--no-wait]` | Mergea (exige pipeline verde) |
| `release <tag> [ref] [notes-file] [milestone]` | Crea release/tag |
| `summary [milestone]` | Reporte de progreso |

`GLAB_PM_YES=1` salta las confirmaciones (modo no interactivo / CI).

### `assets/ci-guard.yml`
Plantilla del job de CI que fuerza "a `main` solo desde `develop`" (no nativo en
GitLab). El agente de código la integra en el `.gitlab-ci.yml`.

## Estructura

```
gl-pm-manager/
├── SKILL.md          # Comportamiento e instrucciones para el agente
├── config.json       # Convenciones (labels, ramas, estilo de mensajes, pipeline)
├── scripts/
│   ├── repo-topology.sh
│   └── glab-pm.sh
├── assets/
│   └── ci-guard.yml
└── README.md
```

## Modelo

- `main`: solo releases con `tag`. `develop`: integración (default).
- Milestone = sprint; toda Issue/MR se asocia a él.
- Labels: feature, fix, task, docs, deploy.
- Mensajes claros y directos, sin firma de autoría; MR a develop con `Closes #N`.
- Pipeline verde antes de mergear; release `develop`→`main` + tag semver.

## Licencia

Uso interno. Adaptar libremente.
