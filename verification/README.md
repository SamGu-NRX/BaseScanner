# Verification (S4)

**Question.** Do the app and server branches do what the plan says? Pass: the app at
`t3/ios-mvf`'s head reaches a result from the real ADVIO replay and keeps its scan; every server
answer at `t3/server`'s head validates against the result schema and never passes without the
coverage its checks need; hostile inputs are refused within 10 s and 500 MB; each plan metric
has evidence at the current head.

**Run**, from `verification/`, with uv (and Xcode 26 with an iOS Simulator for `sim-app`):

```
make sim-app      # REF=, SERVER_REF= or SERVER_URL=
make e2e          # ARGS="--app-export <sim report>"
make scoreboard   # writes SCOREBOARD.md
make test
```

Reports go to `~/house-scanning-data/reports/`, outside git, because replay frames come from
non-commercial datasets. What each check asserts is in the docstrings of `hsverify/e2e.py`,
`resultcheck.py` and `simrun.py`.

**Result.** At `t3/server` `9176125`, with the app's upload from `194f2eb`, all 50 scenes pass (45
answered and checked; slowest real scene 0.24 s).

**What it changed.** S2 fixed seven defects it found:
- unseen ground passing the pool check;
- a short reach cutoff;
- unbounded input cost;
- incomplete photo requests;
- repeated requests past a wall end;
- ground past a real end ignored;
- a facing gap called too close to call.

The friction audit (#61) became team decision 8.
