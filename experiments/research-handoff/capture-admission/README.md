# Capture admission prototype

A requested photo must not become completed capture progress until the returned bytes, returned-frame metadata and task assessment commit together. This standalone SQLite prototype separates capture requests, durable evidence, current requirement support and server acknowledgment.

The published version includes the reviewed fixes: persistent epoch history, current-epoch spatial admission, strict runtime types, transactional requirement updates, consistent read snapshots and refusal to publish uncommitted progress. Earlier tests missed epoch reuse/future-epoch activation and a two-writer revision race; this export contains the corrected implementation, not that historical version.

Run from the repository root with Python 3.10+ on macOS or Linux; only the standard library is used:

```sh
python3 -B -m unittest discover -s experiments/research-handoff/capture-admission -p 'test_*.py' -v
```

Export validation on Python 3.13.7: **26 tests passed** (19 producer controls plus 7 existing independent regression controls). The tests use temporary databases, scheduled concurrent connections and one owned subprocess killed before commit. The regression module retains the existing test bodies with the original review-output/inventory wrapper removed. The implementation and producer test bodies are unchanged. Running `test_admission.py` directly also writes an ignored local receipt.

`usable` and task support are supplied assessments; this code does not establish photo quality, OCR, geometry or installation eligibility. Progress is distinct from upload completion and independent-view count. Matching a local hash/length does not prove remote durable storage. SQLite process-crash rollback at one seam is not a phone power-loss guarantee. The byte-BLOB store, orphan recovery and schema are experiment choices, with no production migration or native camera adapter. No app/server integration, customer media or business thresholds are included.
