# RDM review standards (factory reviewer, profile rdm)

On the changed lines, check:
- `docs/processes/CODING_STANDARDS.md`: explicit types, no `var`, braces, file-scoped namespaces, no new `///`, minimal
  single-line `//` comments that say why, no thrown exceptions.
- The platform standards the repo's `CLAUDE.md` decision tree names for the changed files (Avalonia, Windows, Mac, …).
- For grid code, the `avalonia-datagrid` skill (`.claude/skills/avalonia-datagrid/SKILL.md`): filter logic stays in
  `DevoGridBase`.
- Shared Avalonia controls are themed per platform (DevExpress on Windows, Yaru on Linux, macOS): a template or style
  that replaces a theme's template drops that theme's parts (selection, validation); say whether each theme was checked.

Data flows, for this codebase, includes UI-thread and re-entrancy concerns: CollectionChanged handlers, dispatcher posts,
rebuild storms on bursts of changes.
