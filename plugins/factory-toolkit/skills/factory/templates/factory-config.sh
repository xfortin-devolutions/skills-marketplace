# Team defaults for the factory in this repo (sourced by the factory skill's scripts/lib/config.sh; bash 3.2 compatible).
# Machine-specific values (VM root, CPUs, RAM, budget overrides) go in ~/.factory/config.sh, not here.

DEFAULT_PROFILE=@PROFILE@

B_MODEL=claude-opus-5-5     B_USD=8    B_MIN=45
R_MODEL=claude-sonnet-5-5   R_USD=2    R_MIN=20
QA_MODEL=claude-opus-5-5    QA_USD=6   QA_MIN=40
ITER_CAP=3                  LOOP_USD=40
