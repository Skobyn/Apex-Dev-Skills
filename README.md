# Apex-Dev-Skills

A Claude Code plugin marketplace for Apex Insights development skills and plugins.

## Install the marketplace

```
/plugin marketplace add Skobyn/Apex-Dev-Skills
```

Then install a plugin:

```
/plugin install <plugin-name>@apex-dev-skills
```

Run `/reload-plugins` (or restart Claude Code) to activate.

## Plugins

| Name | Description |
|---|---|
| [apex-plan-loop](plugins/apex-plan-loop) | Decide → plan → loop. SPARC-shaped ADR + phased plan authoring with autonomous `/loop` + `/schedule` execution and per-phase swarm dispatch. |

## Layout

```
.
├── .claude-plugin/
│   └── marketplace.json     # marketplace manifest
├── plugins/
│   └── <plugin-name>/
│       ├── .claude-plugin/plugin.json
│       ├── agents/ commands/ skills/ scripts/
│       └── README.md
└── README.md
```

## Adding a plugin

1. Drop the plugin directory under `plugins/<name>/` with a valid `.claude-plugin/plugin.json`.
2. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`.
3. Commit and push. Users run `/plugin marketplace update apex-dev-skills` to pick up the new entry.

## License

MIT.
