# skills-marketplace (personal, experimental)

Claude Code plugins that are still experimental. They follow the layout of
[Devolutions/skills-marketplace](https://github.com/Devolutions/skills-marketplace), so a plugin graduates there by copying
its folder and its entry in `.claude-plugin/marketplace.json`.

## Install

```
/plugin marketplace add xfortin-devolutions/skills-marketplace
/plugin install factory-toolkit@xfortin-skills-marketplace
```

Restart Claude Code. The repository is private: you need read access to it.

## Plugins

### factory-toolkit (0.x, experimental)

The `factory` skill: turns a Jira ticket into an agent-ready spec with a red oracle, then runs an unattended loop
(builder in its own worktree, the runner's own verify, a read-only reviewer, blind runtime QA in a throwaway VM, then a
blind exploratory QA that tours the change and re-tries its findings on the base build) and hands back to a human judge. Every build and test runs in a QEMU VM of the target OS; the Mac only edits, runs git and drives
the VMs.

- **Engine (this plugin):** the runner, VM tooling, prompts, templates, the reviewer's and QA agent's system prompts, and
  [GAPS.md](plugins/factory-toolkit/GAPS.md), what the loop still lacks.
- **Projects (for now, in this plugin):** each supported repo's `config.sh` and one profile per product
  (`profiles/<name>/`: `profile.sh`, `reviewer.md`, `targets/<os>/` build, test and launch scripts, optional VM layer),
  in [`skills/factory/projects/`](plugins/factory-toolkit/skills/factory/projects/README.md), picked by the repo's
  `origin`. Today: Devolutions/RDM (RDM and Devolutions Console, on Windows). Nothing is committed to the product repo
  except each ticket's spec, on the ticket's own branch. Once a team adopts the factory, its project moves to the repo's
  `.factory/`, which then wins. Ask the skill to "set up a profile for <product>"; the contract is
  [references/profiles.md](plugins/factory-toolkit/skills/factory/references/profiles.md).
- **Per machine:** `~/.factory/config.sh` (VM root, CPUs, RAM, budget overrides) and the golden VM image
  ([references/vm-setup.md](plugins/factory-toolkit/skills/factory/references/vm-setup.md)).

Requirements: macOS on Apple silicon, QEMU, `claude`, `git`, `jq`, `perl`, `python3`; a Windows 11 ARM64 ISO for the
golden image.
