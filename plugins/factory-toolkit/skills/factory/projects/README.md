# Supported projects

While the factory is experimental, each project's configuration ships with the skill instead of living in its repo, so
nothing has to be committed to a product repo to use it. The engine picks the project whose `config.sh` has a
`REPO_MATCH` (an ERE) matching the repo's `origin` remote. A repo that has its own `.factory/profiles/` uses that
instead: that is where a project goes once its team adopts the factory.

| Project | Repo | Product (profile) | Code (`CODE_PATHS`) | Platforms (targets) | VM image |
|---|---|---|---|---|---|
| `devolutions-rdm` | Devolutions/RDM | `rdm`: Remote Desktop Manager (default) | `RDM/` | windows | `base.qcow2` |
| | | `console`: Devolutions Console (Avalonia) | `Console/` | windows | `devolutions-console.qcow2` (layer: `profiles/console/layer/`) |

Not supported yet in that repo: DVLS (`DVLS/`), Hub, DPM and the rest. A ticket there makes the spec step stop and offer
to set the product up first (`factory.sh which <path>` says "no profile").

Each project folder holds `config.sh` (team defaults, `REPO_MATCH`, `DEFAULT_PROFILE`) and `profiles/<product>/`, as
described in `../references/profiles.md`. Tickets never live here: they are working files in the main checkout's
`.claude/worktrees/factory-tickets/`, never committed.

## Add a project or a product

From inside the product's repo: `factory.sh new-profile <product> --skill <project>` creates `projects/<project>/` here
(with a `REPO_MATCH` for the repo's origin) when the repo has none; in a repo that already has a project, `factory.sh
new-profile <product>` adds the product to it (DVLS would join `devolutions-rdm`). Then follow the skill's **profile**
steps, which say what to work out for a new product, and add a row above.

## Move a project into its repo

1. Copy `projects/<project>/config.sh` and `profiles/` to `<repo>/.factory/` (`REPO_MATCH` can stay; it is ignored there).
   Profiles use `$PROFILE_DIR` for their own files, so no path changes.
2. `factory.sh check` from the repo says `project: repo (.factory)`.
3. Commit it through the repo's review, then delete the folder here (or keep it for repos that don't have it yet: the
   repo's copy always wins).
