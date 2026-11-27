# avalonia-extensions review standards (factory reviewer, profile sampleapp)

The repo is **public** (NuGet packages used outside Devolutions). On the changed lines and in every commit message,
check:
- No Devolutions ticket key (DEVEX-…, RDMW-…), Jira or Confluence link, or internal URL, in code, comments, docs, test
  names or commit messages. The behaviour is described instead. Any one is a blocking finding.
- `.claude/CLAUDE.md` (Development, File Modification and Version Control rules): minimal, focused changes; nothing
  tangential fixed on the way (report it instead); no file rewritten beyond what the ticket needs.
- The SampleApp's `/worksetup` state is never committed: `samples/SampleApp/App.axaml` keeps every theme commented out,
  `MainWindow.axaml` selects only the Overview tab, `MainWindowViewModel.cs` keeps `SelectedScale` on
  `AvailableScales[0]`, and no temporary tab selection in `MainWindow.axaml.cs` (`.claude/commands/commit.md`).
- Commit messages follow `[Project] Action description` (Controls, DevExpress, MacOS, Linux, SampleApp, Claude; Add,
  Update, Fix).
- A control in `src/Devolutions.AvaloniaControls` is a library API: a public or styled/attached property changed or
  removed is a breaking change for package users; a new behaviour that changes what existing users see is opt-in unless
  the ticket says otherwise. Follow the surrounding controls' conventions (property registration, naming, file layout).
- A theme change stays in that theme's `Controls/` styles and resources (`ThemeRoot.axaml`); a change in
  `Devolutions.AvaloniaControls` must still work under every theme (DevExpress, WinUI, MacOS, Linux), not only the one
  the SampleApp opened.
- SampleApp pages follow the page catalog (`samples/SampleApp/PageCatalog/page-catalog.jsonc`, `.claude/CLAUDE.md`
  "Runtime Navigation Convention").
- Visual baselines (`tests/Devolutions.AvaloniaControls.VisualTests/Screenshots/Baseline/`) change only for an intended
  appearance change the ticket asks for, never for unfinished styling (`AGENTS.md`, "Visual baseline approval"); only the
  Windows themes' (DevExpress, WinUiClassic, WinUiMica) can be produced in this factory's guest. `LocalBaselines/` is
  never committed. Missing cross-platform baselines are not a finding (`.github/copilot-instructions.md`).
- Functional tests go in `tests/Devolutions.AvaloniaControls.Tests` (Avalonia.Headless.XUnit, xUnit v3) and assert what
  a user sees (sizes, text, selection), not private state.
- A theme's `CHANGELOG.md` changes only for a substantial or breaking change.

Data flows, for this codebase, means the UI thread and layout: work done in `MeasureOverride`/`ArrangeOverride`, on
popup open or per item stays bounded (no measure loop over an unbounded collection without a cap); subscriptions made by
attached properties or `OnApplyTemplate` are released (template re-applied, control detached, `ItemsSource` replaced),
so nothing leaks or fires twice.
