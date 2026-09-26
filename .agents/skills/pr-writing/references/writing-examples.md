# Writing examples

These invented examples illustrate the level of explanation. They are not facts to reuse in a PR.

## Explain the failure and mechanism

Weak: "Improved session handling. The stale-response guard is robust and all tests pass."

Useful: "Switching accounts while the inbox loaded could show the previous account's messages. The response now carries the account that requested it, and the inbox discards it if that account is no longer active. The regression test starts both loads and completes the older request last."

The useful version names the trigger, consequence and mechanism. A test count alone would not explain why the race is covered.

## Make a small change small to read

Title: "fix(export): preserve zero values in CSV downloads"

"CSV downloads left zero-valued cells empty because the formatter treated every falsy value as missing. It now leaves a cell empty only for null or undefined. `npm run test:csv` passes, including zero, null and undefined cases."

No architecture narrative or screenshot is needed for this change. Follow required repository sections without padding them.

## Describe what a comparison establishes

"The payment error used to replace the form and discard the entered address. It now appears above the submit button, leaving the address available for a retry."

Place the matched images immediately below that explanation. A caption such as "Same declined-payment fixture at 390 × 844; before a12bc34, after d56ef78" establishes the comparison. If no live charge ran, say so once beside the verification. Do not call the images proof that payments work end to end.

## Preserve a useful limit

"The migration was exercised on a copy of the staging schema. Production data volume and lock duration have not been measured."

This gives the reviewer a concrete remaining concern. "Low risk, thoroughly tested" hides it. A long chronology of failed approaches would bury it.
