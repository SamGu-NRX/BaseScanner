# Build 4.1 field test: three analysed runs

TestFlight build 4.1 (`beta` at `45017ba`) was recorded three times on 2026-09-26, and each recording was analysed in its
own session. Each report lists issues with stable IDs so they can be compared and deduplicated before filing.

| Report | Recording | Site | Phone | IDs |
|---|---|---|---|---|
| [run1-2000.md](run1-2000.md) | 20:00, 6 min 49 s | Mock wall, indoors | iPhone 14, no LiDAR | `A41-1-…` |
| [run2-2015.md](run2-2015.md) | 20:15 | Mock wall, indoors | iPhone 14, no LiDAR | `A41-2015-…` |
| [run3-2055.md](run3-2055.md) | 20:55 | A real house, outdoors at night | iPhone 14, no LiDAR | `A41-2055-…` |

These are commit-safe copies: meter numbers are removed. Videos, frames, transcripts, scan zips and server re-runs stay
in the gitignored `private/device-test-4.1-*/` folders on the analysing machine. Run 3's media shows a real address.
