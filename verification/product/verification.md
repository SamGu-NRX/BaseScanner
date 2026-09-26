# Checks against the running app

Each row is one claim from a document, checked in the Simulator on `21a63e7`. A failed row is not
automatically an app bug: sometimes the document is wrong, and the note says which. Screenshots
stay in `~/house-scanning-data/reports/sim/` because replay frames come from a non-commercial
dataset.

## How a pass is run

`make sim REF=21a63e7 ARGS="--replay ~/house-scanning-data/replays/advio-20-0040-0075 --autopilot
--server-url http://127.0.0.1:8765 --extra-arg=-autopilotHold --extra-arg=3"`, with the server
from `t3/server` on port 8765. The runner screenshots each screen and records the app's own log.
What this covers: the order of screens, what each shows, and what the app logged. What it does
not cover: anything needing the live camera (tracking, the meter tap on a real wall, the close-up
succeeding), haptics, or timing felt by a person.

## Pass 1: 2026-09-26 04:06, report `20260926-040635-21a63e7-21a63e72-int-replay`

| ID | Claim | Result |
| --- | --- | --- |
| FLOW-01 | Screens appear in the order of [the flow](foundations/flow.md#the-interaction-event-by-event) | Pass up to `uploading`: onboarding, findMeter, meterCloseUp, wallWalk, markFeatures, gapRequest, uploading. |
| FLOW-02 | The result appears only after the server answered | Pass, in the bad sense: the upload got 404 (see B-01) and the app stayed on `uploading`. |
| UP-01 | A failed upload offers "Try again" | Fail: the screenshot shows "That didn't go through" and the raw server JSON, with no button and no emblem visible (see B-02, B-05). |
| CU-01 | Without a usable photo, the close-up is skipped after the second failed try | Pass on the replay: logged "close-up skipped after 2 failed attempts" after 4 s. |
| CU-02 | The instruction card shows "Hold your meter in the circle" | Fail: the card is an empty panel in the screenshot (see B-05). |
| WW-01 | The walk shows one instruction, the strip and its labels | Fail: every card and the strip render without text (see B-05). |
| MF-01 | The feature list is readable over the dimmed camera | Fail: black text directly on the camera image, no panel (see B-05). |
| GAP-01 | A gap request appears when the phone's check finds a gap | Pass: shown, then skipped by the autopilot because this replay has no held-back frames. |

Not checked yet: `result` and `resultAR` (unreachable while B-01 stands; a `-sampleResult` pass
is next), larger text sizes, dark appearance, and failure screens (launch with `-replay
/nonexistent` for B-03).
