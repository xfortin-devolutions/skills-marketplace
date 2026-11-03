# @NAME@
<!-- A resource only a human can provide, for the factory's QA. Agents read this file (the assessor, to match a ticket's
test needs; QA, to use it): never put a secret in it. The files next to it are copied into each QA VM, at
C:\factory\provided\@NAME@, and nowhere else. -->
What: <one line, in user terms: "a DVLS data source with a working Dashboard entry">
Use: <how QA reaches it in the app: "open the data source 'Lab DVLS' from the data source list; sign in with the saved credentials">
Access: <read-only | scratch> (read-only: QA looks and uses, never changes or deletes what is there; scratch: QA may change it)
Shared: <yes | no> (no: one run at a time uses it; the others wait)

<Anything else a tester must know: what is in it, what it must not do. No secrets.>
