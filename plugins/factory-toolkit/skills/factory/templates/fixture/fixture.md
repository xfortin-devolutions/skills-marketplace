# @NAME@
<!-- A fixture: state a fresh install of the app lacks, put in place in every QA VM before the app starts. It belongs to
its ticket (<KEY>.fixtures/<name>/ next to the spec, never committed, deleted by factory.sh clean <KEY>). The assessor
reads What; QA gets Use. Agents read this file: no secrets. -->
What: <one line, in user terms: "an RDP entry with a linked credential in the default data source">
Use: <where QA finds it in the app: "the entry 'Server A' in the 'Fixtures' folder of the navigation pane">
