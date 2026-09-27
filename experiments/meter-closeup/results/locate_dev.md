### Barcodes

| Photos | Barcode found | Decoded | Decode contains the meter number |
|---|---|---|---|
| 42 | 13 | 13 | 12 of 12 with a labelled number |

### Finding the number

**all photos: 38 with an agreed number, 38 read**

| Rule | Picks | Precision | Recall over read photos |
|---|---|---|---|
| tallest digit line (phase 1) | 38 | 10/38 = 26% (15%–42%) | 10/38 = 26% (15%–42%) |
| barcode confirms a text line | 12 | 11/12 = 92% (65%–99%) | 11/38 = 29% (17%–45%) |
| line nearest a decoded barcode | 11 | 7/11 = 64% (35%–85%) | 7/38 = 18% (9%–33%) |
| after a No./Nr./#: keyword | 10 | 6/10 = 60% (31%–83%) | 6/38 = 16% (7%–30%) |
| alone on its line, 6-14 characters, not a spec line | 37 | 22/37 = 59% (43%–74%) | 22/38 = 58% (42%–72%) |
| combined: barcode, else keyword | 19 | 16/19 = 84% (62%–94%) | 16/38 = 42% (28%–58%) |
| ranking, top 1 | 38 | – | 27/38 = 71% (55%–83%) |
| ranking, top 3 | 38 | – | 36/38 = 95% (83%–99%) |
| number is any candidate (ceiling) | 38 | – | 37/38 = 97% (87%–100%) |
