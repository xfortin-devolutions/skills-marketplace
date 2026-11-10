# skills-marketplace (personal, experimental)

Claude Code plugins that are still experimental. They follow the layout of
[Devolutions/skills-marketplace](https://github.com/Devolutions/skills-marketplace), so a plugin graduates there by copying
its folder and its entry in `.claude-plugin/marketplace.json`.

## Install

```
/plugin marketplace add xfortin-devolutions/skills-marketplace
/plugin install vm-toolkit@xfortin-skills-marketplace
/plugin install factory-toolkit@xfortin-skills-marketplace
```

`factory-toolkit` needs `vm-toolkit`; `vm-toolkit` works on its own.

Restart Claude Code. The repository is private: you need read access to it.

## Plugins

### vm-toolkit (0.x, experimental)

The `vm` skill and an MCP server (`vm`): throwaway QEMU VMs of the OS a product ships on, cloned per use from a read-only
golden image, sharing a worktree live as `R:`. Build and test in the guest, launch the app in its desktop, take
screenshots and drive it, apply test data, open it in Screen Sharing. The factory runs its loop on it; any agent can use
it too (the MCP server for other harnesses, e.g. a FleetView agent).

- **Product definitions:** what each product is and how its VM builds, tests and launches it (`product.sh`,
  `targets/<os>/` scripts, optional VM layer): the repo's `.vm/`, else bundled in
  [`skills/vm/projects/`](plugins/vm-toolkit/skills/vm/projects/), picked by the repo's `origin`. Today: Devolutions/RDM
  (RDM and Devolutions Console, on Windows). Contract:
  [references/products.md](plugins/vm-toolkit/skills/vm/references/products.md).
- **Per machine:** `~/.vm-toolkit/config.sh` (VM root, CPUs, RAM, slots) and the golden VM image
  ([references/vm-setup.md](plugins/vm-toolkit/skills/vm/references/vm-setup.md)).
- [GAPS.md](plugins/vm-toolkit/GAPS.md): what the VMs still lack.

### factory-toolkit (0.x, experimental)

The `factory` skill: turns a Jira ticket into an agent-ready spec with a red oracle, then runs an unattended loop
(builder in its own worktree, the runner's own verify, a read-only reviewer, blind runtime QA in a throwaway VM, then a
blind exploratory QA that tours the change and re-tries its findings on the base build) and hands back to a human judge. Every build and test runs in a QEMU VM of the target OS (vm-toolkit's); the Mac only edits, runs git
and drives the VMs.

- **Engine (this plugin):** the runner, prompts, templates, the reviewer's and QA agent's system prompts, and
  [GAPS.md](plugins/factory-toolkit/GAPS.md), what the loop still lacks.
- **Projects (for now, in this plugin):** each supported repo's `config.sh` and one profile per product
  (`profiles/<name>/`: `profile.sh`, `reviewer.md`: the factory's settings on top of vm-toolkit's product definition),
  in [`skills/factory/projects/`](plugins/factory-toolkit/skills/factory/projects/README.md), picked by the repo's
  `origin`. Today: Devolutions/RDM (RDM and Devolutions Console, on Windows). Nothing is committed to the product repo
  except each ticket's spec, on the ticket's own branch. Once a team adopts the factory, its project moves to the repo's
  `.factory/`, which then wins. Ask the skill to "set up a profile for <product>"; the contract is
  [references/profiles.md](plugins/factory-toolkit/skills/factory/references/profiles.md).
- **Dashboard:** `factory.sh dashboard` (or ask the skill "show me the dashboard") opens a live local page of the runs:
  each run's pipeline, what the running agent is doing, the builder's changes, QA screenshots as they're taken.
- **Per machine:** `~/.factory/config.sh` (budget overrides, the size table), on top of vm-toolkit's.

Requirements: macOS on Apple silicon, QEMU, `claude`, `git`, `jq`, `perl`, `python3`; a Windows 11 ARM64 ISO for the
golden image.
