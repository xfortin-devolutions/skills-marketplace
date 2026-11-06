# Project: the Devolutions/RDM repo (RDM, Devolutions Console). Team defaults, sourced by the factory skill's
# scripts/lib/config.sh; bash 3.2 compatible. Bundled with the skill while the factory is experimental; moving it to the
# repo is copying this folder to <repo>/.factory/ (the repo's .factory/profiles then wins).
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

# Which repo this project is for: an ERE on its origin remote URL (ignored once the project lives in the repo).
REPO_MATCH='[:/]Devolutions/RDM(\.git)?$'

DEFAULT_PROFILE=rdm
# The dashboard: http://rdm.factory.localhost:8765/
DASHBOARD_NAME=rdm          DASHBOARD_PORT=8765
# The repo's own PR instructions, read first by the PR writer (factory.sh pr, run --open-pr); each must exist at run time.
PR_INSTRUCTIONS=".claude/skills/pull-request-rdm/SKILL.md docs/processes/GIT_PULL_REQUEST.md"
# Docs a change may always update (skills: the .claude side; .agents/ and AGENTS.md are symlinks to it). The DVLS and
# Console folders carry their own skills and CLAUDE.md, which a Console change makes wrong as often as the root ones.
DOC_PATHS=".claude/skills/ docs/ CLAUDE.md DVLS/.claude/skills/ DVLS/CLAUDE.md Console/.claude/skills/ Console/CLAUDE.md"

# Builder: 75 min. It only checks its work in the guest (a project build, the accept test); the runner's verify does the
# full build, the tests and the negative run after it.
B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=75
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
# Exploratory QA after a runtime QA PASS: charter (from the diff), explorer (same VM), re-check of findings on the base.
C_MODEL=claude-sonnet-5-5   C_USD=1    C_MIN=10
X_MODEL=claude-opus-5-5     X_USD=5    X_MIN=30    RC_USD=3   RC_MIN=20
EXPLORE=yes                 EXPLORE_SENDBACKS=1
ITER_CAP=5                  STALL_CAP=2               LOOP_USD=40
# Size classes (references/test-needs.md): the assessor picks one per ticket, SIZE in the ticket .sh overrules it. M is
# the defaults above. A guest build of RDM takes 8 to 15 min, so even an S round keeps an hour; an L or XL round has to
# fit a full rebuild and several test runs. SIZE_CEILING caps the assessor's class only (~/.factory/config.sh may lower it).
SIZE_S="B_USD=6 B_MIN=60 ITER_CAP=4 LOOP_USD=25"
SIZE_M=""
SIZE_L="B_USD=15 B_MIN=120 R_USD=3 R_MIN=30 QA_USD=8 QA_MIN=60 X_USD=7 X_MIN=45 ITER_CAP=6 LOOP_USD=80"
SIZE_XL="B_USD=25 B_MIN=180 R_USD=4 R_MIN=40 QA_USD=10 QA_MIN=75 X_USD=8 X_MIN=60 ITER_CAP=8 LOOP_USD=150"
SIZE_CEILING="LOOP_USD=150 B_USD=25 B_MIN=180"
