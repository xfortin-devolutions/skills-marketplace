# Devolutions Console review standards (factory reviewer, profile console)

On the changed lines, check:
- `Console/CLAUDE.md`, which supplements `RDM/Shared/Avalonia/Core/CODING_STANDARDS.md` and
  `RDM/Shared/Avalonia/Core/CLAUDE.md`: explicit types, `this.` on instance members, camelCase private members,
  trailing commas, static lambdas, no `#region`, no `#nullable enable`, no `async void`, no new `///`, minimal `//`.
- Under `DVLS/Console/Console.Common` (shared with the legacy console and the CLI): `DVLS/CLAUDE.md` instead, with the
  surrounding files' conventions (`DPS.Console.Common…` namespaces, `#nullable disable` where a file has it); it builds
  for `Console.Linux` too, so no Windows-only API outside the Windows path.
- Namespaces follow the folder (`Devolutions.Console…`), except ViewModels (always `Devolutions.Console.ViewModels`) and
  `Views/**` (`Devolutions.Console.Views`). Never the bare `Console` namespace.
- MVVM is Devolutions.MvvmToolkit (`[ObservableProperty]`) and Devolutions.Roslyn (`[RelayCommand]`), never
  CommunityToolkit. Collections are `AvaloniaList<T>`.
- AXAML: `{UIDynRes}` / `{MsgDynRes}`, never `{UIRes}` / `{MsgRes}` (live language switching); the Console's
  `<FormGrid>`, never `<Grid Classes="form">`; a dialog is a `ChromeWindow`, never a bare `Window`; `<Label Target=…>`.
- Grids are `DevoDataGrid` (skill `avalonia-datagrid`), as in the instance list and the database windows, never a raw
  `DataGrid`; every column fits, or the grid scrolls, at the window's opening size.
- The Console skills the change needed: `ui-services-console` (messages, questions, busy state), `add-dialog-console`,
  `run-command-console`; the ribbon follows `Console/Doc/RIBBON_GUIDE.md`.
- Platform code sits behind a `<Feature>ServiceLocator` service, never an `OperatingSystem.IsWindows()` or a null check in
  a ViewModel. The factory builds only Windows (`Console/Console.Windows.slnf`): say whether shared code now depends on a
  Windows-only API that `Console.Linux` would not have.
- Native AOT: no reflection, no new dependency that blocks trimming.
- Tests in `Console/Console.Shared.Tests` use public API only (no `InternalsVisibleTo`) and no Avalonia application.

Data flows, for this codebase, includes: async I/O only (no `.Result`, no `.Wait()`, nothing blocking the UI thread),
commands that run `DPS.Console.Common` work with live output, and secrets (database and administrator credentials never
logged or shown in clear).
