# Team defaults for the factory in this repo (sourced by the factory skill's scripts/lib/config.sh; bash 3.2 compatible).
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

DEFAULT_PROFILE=@PROFILE@
# Docs a change may always update besides the ticket's scope (repo path prefixes), e.g. ".claude/skills/ docs/ CLAUDE.md".
DOC_PATHS=""

B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=45
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
# Exploratory QA after a runtime QA PASS: charter (from the diff), explorer (same VM), re-check of findings on the base.
C_MODEL=claude-sonnet-5-5   C_USD=1    C_MIN=10
X_MODEL=claude-opus-5-5     X_USD=5    X_MIN=30    RC_USD=3   RC_MIN=20
EXPLORE=yes                 EXPLORE_SENDBACKS=1
ITER_CAP=5                  STALL_CAP=2               LOOP_USD=40
# Size classes: the assessor picks one per ticket, and it sets the limits it names (the others keep the values above);
# SIZE in a ticket's .sh, --size and --set overrule it. SIZE_CEILING caps what the assessor's class can buy. Tune these
# on factory-runs/.calibration.tsv (references/test-needs.md).
SIZE_S="B_MIN=30 ITER_CAP=4 LOOP_USD=25"
SIZE_M=""
SIZE_L="B_USD=15 B_MIN=90 R_USD=3 R_MIN=30 QA_USD=8 QA_MIN=60 X_USD=7 X_MIN=45 ITER_CAP=6 LOOP_USD=80"
SIZE_XL="B_USD=25 B_MIN=150 R_USD=4 R_MIN=40 QA_USD=10 QA_MIN=75 X_USD=8 X_MIN=60 ITER_CAP=8 LOOP_USD=150"
SIZE_CEILING="LOOP_USD=150 B_USD=25 B_MIN=180"
