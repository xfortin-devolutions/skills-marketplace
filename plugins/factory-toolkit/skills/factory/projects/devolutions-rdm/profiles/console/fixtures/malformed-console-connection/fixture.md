# malformed-console-connection
<!-- A fixture: state a fresh install of the app lacks, put in place in every QA VM before the app starts. The assessor
matches tickets' test needs on What; QA gets Use. Committed with the profile: no secrets. -->
What: the IIS instance /dvls (SQL Server Express) with an unparseable console connection string (ConnectionStrings.LocalSqlServer in its appsettings.json set to `Data Source=HOST\SQLEXPRESS;Initial Catalog`, no `=` after the last key), its original connection values saved for a repair; the other instances (/dvls-pg, /dvls-sqlite, Kestrel) untouched
Use: the broken instance is /dvls (Default Web Site/dvls); the other three are healthy. Its original connection values, one per line (Data Source, Initial Catalog, User ID, Password, ...), are in "dvls original connection.txt" on the desktop: open it with Notepad to repair the instance, and don't quote its Password line in your report
