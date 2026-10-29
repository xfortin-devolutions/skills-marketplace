# Project: the Devolutions/RDM repo (RDM, Devolutions Console). Team defaults, sourced by the factory skill's
# scripts/lib/config.sh; bash 3.2 compatible. Bundled with the skill while the factory is experimental; moving it to the
# repo is copying this folder to <repo>/.factory/ (the repo's .factory/profiles then wins).
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

# Which repo this project is for: an ERE on its origin remote URL (ignored once the project lives in the repo).
REPO_MATCH='[:/]Devolutions/RDM(\.git)?$'

DEFAULT_PROFILE=rdm
# Docs a change may always update (skills: the .claude side; .agents/ and AGENTS.md are symlinks to it).
DOC_PATHS=".claude/skills/ docs/ CLAUDE.md"

B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=45
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
# Exploratory QA after a runtime QA PASS: charter (from the diff), explorer (same VM), re-check of findings on the base.
C_MODEL=claude-sonnet-5-5   C_USD=1    C_MIN=10
X_MODEL=claude-opus-5-5     X_USD=5    X_MIN=30    RC_USD=3   RC_MIN=20
EXPLORE=yes                 EXPLORE_SENDBACKS=1
ITER_CAP=3                  LOOP_USD=40
