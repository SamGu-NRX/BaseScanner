# Meter close-up readability

The app photographs the electric meter so Base can read its meter number and its class label (CL200, CL320). A homeowner must not be asked for photos again, so the phone has to decide before they leave whether a close-up is readable. This experiment measures that on real meter photos.

## Questions

1. How often does Apple's on-device text recognition (Vision `VNRecognizeTextRequest`, revision 3, the engine the iPhone app would call) read the full meter number and the class label correctly?
2. Which cheap photo checks (sharpness, glare, label height in pixels, framing) predict a failed read, and at what thresholds?
3. Does a second pass (crop the detected label and read again) raise the read rate?

## Pass criteria, set before the run

- Q1 is a measurement. If on-device reading gets the full meter number right on at least 90% of usable close-ups, the phone can gate capture on its own read. Below 70%, the phone should gate on photo quality and a server should do the reading.
- A photo check is useful if, above its threshold, at least 95% of the photos that read correctly when undegraded still read correctly after controlled degradation.

Status: in progress.
