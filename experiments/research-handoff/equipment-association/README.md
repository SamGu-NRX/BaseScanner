# Equipment evidence association prototype

A continuing tracker UUID does not establish that a label belongs to the intended enclosure. This standalone, in-memory event reducer preserves source observations, requires explicit contextual nomination and per-label review records, and makes superseded attachments historical after revisions, contradictions or resets.

The published implementation is **fix v2**. It permits at most one ticket per candidate/label/candidate-revision, across all ticket states. An earlier version allowed a sibling ticket's late decision to overrule newer same-pair intent. The corrected version refuses that duplicate atomically; exact event replay remains idempotent. The same unresolved ticket can receive a fresh-revision review, and a new nomination/reset context permits a new ticket while preserving history.

Run from the repository root with Python 3.10+; only the standard library is used:

```sh
python3 -B experiments/research-handoff/equipment-association/test_association.py
```

Export validation on Python 3.13.7: **11 tests passed**, including four sibling-ticket regressions. The source and synthetic fixture are unchanged from reviewed v2; only the test module's stale preparation-time docstring was updated. The fixture's `cases` list describes the seven original scenarios; the test module includes the four later regressions.

All photo references, hashes, labels and reviewer actions are invented. No image is loaded. Explicit review fields are software assertions, not verification of a person's inspection or physical equipment identity. Tracker confidence and label text cannot automatically attach evidence. The proposed sidecar is not integrated with the app, scene consumer or capture-admission prototype. Persistence, UI authorization, production concurrency and migration of historical duplicate tickets remain outside this experiment.
