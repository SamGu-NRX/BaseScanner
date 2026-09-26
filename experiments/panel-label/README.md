# Panel label readability

Installers check the main electrical panel's manufacturer, model and main breaker amperage. Some panel lines are known hazards: Federal Pacific Stab-Lok and Zinsco are both subjects of public safety notices. The main breaker's amperage matters for any battery install. If the phone can read a close-up of the panel label, a homeowner can answer with one photo instead of a form. This experiment measures that on real, openly licensed panel photos, reusing the meter close-up tooling.

## Questions and pass criteria, set before the run

1. How often does Vision's `accurate` mode read the manufacturer, the model or series, and the main breaker's amperage? Each field is scored on the photos where both AI readers agree it is legible, under the strict rule (both readers transcribed the same text and were sure). One photo can replace the form if the manufacturer and the main amperage are each read on at least 90% of those photos; below 70%, keep the form.
2. Can a simple rule map the recognized text to a manufacturer from a small public list, including the known-hazard lines? Precision (the named manufacturer is right, among photos where the rule names one) and recall (over photos with an agreed manufacturer) are reported on held-out photos. The rule may name a manufacturer without asking the homeowner if its held-out precision is at least 95%. To limit fitting, the rules are written using only odd-numbered photos and committed before the even-numbered ones are scored.
3. Do the meter close-up's blur and too-small checks transfer to panel labels? They transfer if, on the same controlled degradations of the panel photos, the panel's own 95% break-point threshold for each check is no stricter than the meter's (whole-photo sharpness 6.63; top-candidate line height 33.9 px). Otherwise the panel needs its own thresholds, which are reported.

If fewer than about 40 usable openly licensed photos exist, the experiment stops there and reports what was searched.
