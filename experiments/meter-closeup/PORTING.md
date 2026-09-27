# Meter close-up checks for the app

This is the reference for the iOS owner. `src/meter_eval/retake.py` and `src/meter_eval/locate.py` implement the same definitions, and `tests/test_retake.py` holds hand-computed cases. [METHODS.md](METHODS.md) says where each threshold comes from.

## Flow

1. Run the focus check. If it fails, ask for a retake.
2. Read the close-up and rank the candidates.
3. Show the three best candidates, a barcode-confirmed one first, and "none of these".
4. If the homeowner taps a candidate, keep it. A confirmed number needs no readability check.
5. If the homeowner taps "none of these", ask for a retake. If the size check fails, say "move closer".

No measured check exists for glare, framing or hand shake, so prompts about them can only be general advice.

## Reading and ranking

- Text: `VNRecognizeTextRequest`, revision 3, `.accurate`, `en-US`, `usesLanguageCorrection = false`, `minimumTextHeight = 0`.
- Barcodes: `VNDetectBarcodesRequest`, revision 4, all symbologies, on the same image.
- Candidates, features and score: `locate.py` (`candidates`, `score`, `ranked`).

## Checks

Every check runs on the full-resolution photo after its EXIF orientation is applied. Luma is the 8-bit image L = 0.299 R + 0.587 G + 0.114 B. A box is Vision's normalized `boundingBox`, converted to a top-left origin.

| Check | Input | Formula | Retake when |
|---|---|---|---|
| Out of focus | the whole photo, as luma | Shrink so the long side is 1024 px (bilinear with antialiasing, as PIL does); leave smaller photos as they are. Convolve with the Laplacian [[0,1,0],[1,−4,1],[0,1,0]] over interior pixels, and take the population variance. | 6.68 or less |
| Number too small | the top candidate's box | box height × photo height, in pixels | 33.9 px or less |
| No number | the ranking | no candidate at all | always |
