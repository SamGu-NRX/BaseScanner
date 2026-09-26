"""A local page for a person to confirm the AI-made meter-number labels.

`build` writes REVIEW_DIR/review.html and a crop of each photo's number. The page shows the
crop beside the number both AI readers settled on; the reviewer keeps it (K) or types a
correction (F, then Enter) and downloads the answers as CSV. `ingest` copies that CSV to
DATA_DIR/labels_human.csv, where `labels.py` picks it up. Everything stays outside git,
because the page shows plaintext meter numbers.
"""

import argparse
import csv
import json
import shutil

from PIL import Image

from meter_eval.paths import DATA_DIR, MANIFEST, RESULTS_DIR, REVIEW_DIR

HUMAN_LABELS = DATA_DIR / "labels_human.csv"


def crop_number(image: Image.Image, box: list[float] | None) -> Image.Image:
    """The number's line with context around it, or the whole photo if it was never read."""
    if box is None:
        view = image.copy()
    else:
        x, y, w, h = box
        pad_x, pad_y = 0.3 * w, 1.5 * h
        view = image.crop(
            (
                round(max(0.0, x - pad_x) * image.width),
                round(max(0.0, y - pad_y) * image.height),
                round(min(1.0, x + w + pad_x) * image.width),
                round(min(1.0, y + h + pad_y) * image.height),
            )
        )
    view.thumbnail((960, 720))
    return view


def build() -> None:
    with MANIFEST.open() as handle:
        manifest = [r for r in csv.DictReader(handle) if r["usable"] == "yes"]
    with (DATA_DIR / "labels_reader1.csv").open() as handle:
        first = {r["id"]: r for r in csv.DictReader(handle)}
    second = {}
    for name in ("labels_reader2a.csv", "labels_reader2b.csv"):
        with (DATA_DIR / name).open() as handle:
            second |= {r["id"]: r for r in csv.DictReader(handle)}
    with (RESULTS_DIR / "clean_per_image.csv").open() as handle:
        boxes = {r["id"]: r["number_box"] for r in csv.DictReader(handle)}

    crops = REVIEW_DIR / "crops"
    crops.mkdir(parents=True, exist_ok=True)
    items = []
    for row in manifest:
        image_id = row["id"]
        source = DATA_DIR / "images" / f"{image_id}.jpg"
        box = json.loads(boxes[image_id]) if boxes.get(image_id) else None
        with Image.open(source) as image:
            crop_number(image, box).save(crops / f"{image_id}.jpg", quality=85)
        number = first[image_id]["meter_number"]
        other = second[image_id]["meter_number"]
        items.append(
            {
                "id": image_id,
                "number": "" if number == "NONE" else number,
                "agreed": row["number_agreed"] == "yes",
                "other": "" if other in ("NONE", number) else other,
                "note": first[image_id]["notes"],
                "photo": source.as_uri(),
                "page": row["page_url"],
            }
        )
    # Inside <script> only "</" can end the element early; entities would not be decoded.
    page = TEMPLATE.replace("__ITEMS__", json.dumps(items).replace("</", "<\\/"))
    (REVIEW_DIR / "review.html").write_text(page)
    print(f"{len(items)} photos -> {REVIEW_DIR / 'review.html'}")


def ingest(path: str) -> None:
    with open(path) as handle:
        rows = list(csv.DictReader(handle))
    missing = {"id", "verdict", "number"} - set(rows[0])
    if missing:
        raise SystemExit(f"{path} lacks columns {sorted(missing)}; export it from review.html")
    shutil.copyfile(path, HUMAN_LABELS)
    fixed = [r for r in rows if r["verdict"] == "fix"]
    print(f"{len(rows)} answers, {len(fixed)} corrections -> {HUMAN_LABELS}")
    for r in fixed:
        print(f"  {r['id']}: corrected")
    print("Rebuild the manifest with `python -m meter_eval.labels`, then rerun the tables.")


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meter number check</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Overpass+Mono:wght@400;600&family=Public+Sans:wght@400;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --plate: #e7e9e6;
    --plate-deep: #d5d9d4;
    --ink: #1c2124;
    --muted: #5b6468;
    --glass: #2f6b6a;
    --seal: #c8402f;
    --amber: #b7850f;
    --paper: #f7f8f6;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--plate); color: var(--ink);
    font: 15px/1.45 "Public Sans", ui-sans-serif, sans-serif;
  }
  header {
    position: sticky; top: 0; z-index: 2; background: var(--ink); color: var(--paper);
    display: flex; flex-wrap: wrap; gap: 12px 28px; align-items: baseline;
    padding: 14px 24px;
  }
  header h1 { font-size: 17px; margin: 0; font-weight: 700; }
  header p { margin: 0; color: #c9d0d2; }
  kbd {
    font: 600 12px "Overpass Mono", ui-monospace, monospace; padding: 1px 6px;
    border: 1px solid #6c777b; border-radius: 3px; color: var(--paper);
  }
  .progress { font: 600 15px "Overpass Mono", ui-monospace, monospace; margin-left: auto; }
  button.export {
    font: 600 14px "Public Sans", sans-serif; color: var(--ink); background: var(--paper);
    border: 0; border-radius: 4px; padding: 7px 14px; cursor: pointer;
  }
  main { max-width: 1180px; margin: 0 auto; padding: 20px 24px 60vh; }
  article {
    display: grid; grid-template-columns: minmax(0, 3fr) minmax(280px, 2fr); gap: 22px;
    background: var(--paper); border: 2px solid transparent; border-radius: 6px;
    padding: 14px; margin-bottom: 10px;
  }
  article.current { border-color: var(--glass); }
  article[data-verdict="keep"] { opacity: 0.55; }
  article[data-verdict="fix"] { border-left: 6px solid var(--seal); }
  article img {
    width: 100%; height: auto; max-height: 280px; object-fit: contain; object-position: left;
    border-radius: 3px;
  }
  .meta { display: flex; gap: 10px; align-items: baseline; color: var(--muted); font-size: 13px; }
  .meta a { color: var(--glass); }
  .stamp {
    font: 600 clamp(26px, 3.4vw, 40px)/1.1 "Overpass Mono", ui-monospace, monospace;
    letter-spacing: 0.06em; margin: 10px 0 6px; padding: 10px 14px;
    border: 2px solid var(--ink); border-radius: 4px; display: inline-block;
    background: var(--plate); word-break: break-all;
  }
  .stamp.none { font-size: 18px; letter-spacing: 0; color: var(--muted); border-style: dashed; }
  .flag { color: var(--amber); font-weight: 600; margin: 4px 0; }
  .note { color: var(--muted); font-size: 13px; margin: 4px 0 12px; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  .actions button {
    font: 600 14px "Public Sans", sans-serif; border-radius: 4px; padding: 8px 14px;
    cursor: pointer; border: 2px solid var(--ink); background: var(--paper); color: var(--ink);
  }
  .actions button[aria-pressed="true"].keep { background: var(--ink); color: var(--paper); }
  .actions button[aria-pressed="true"].fix { background: var(--seal); border-color: var(--seal); color: #fff; }
  .actions input {
    font: 600 18px "Overpass Mono", ui-monospace, monospace; padding: 7px 10px; width: 100%;
    border: 2px solid var(--seal); border-radius: 4px;
  }
  .actions input[hidden] { display: none; }
  :focus-visible { outline: 3px solid var(--glass); outline-offset: 2px; }
  @media (max-width: 760px) { article { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<header>
  <h1>Meter number check</h1>
  <p>Does the stamp match the photo? <kbd>K</kbd> keep <kbd>F</kbd> fix
     <kbd>Enter</kbd> save fix <kbd>&uarr;</kbd><kbd>&darr;</kbd> move</p>
  <span class="progress" id="progress"></span>
  <button class="export" id="export">Download answers</button>
</header>
<main id="list"></main>
<script type="application/json" id="items">__ITEMS__</script>
<script>
const items = JSON.parse(document.getElementById("items").textContent);
const saved = JSON.parse(localStorage.getItem("meter-check") || "{}");
const list = document.getElementById("list");
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
let current = 0;

function render() {
  for (const [i, item] of items.entries()) {
    const answer = saved[item.id] || {};
    const el = document.createElement("article");
    el.id = item.id;
    el.dataset.verdict = answer.verdict || "";
    const stamp = item.number
      ? `<div class="stamp"></div>`
      : `<div class="stamp none">No number labelled</div>`;
    el.innerHTML = `
      <img loading="lazy" alt="Photo ${item.id}, cropped to the meter number" src="crops/${item.id}.jpg">
      <div>
        <div class="meta"><b>${item.id}</b>
          <a href="${item.photo}" target="_blank">full photo</a>
          <a href="${item.page}" target="_blank">source</a></div>
        ${stamp}
        <div class="flag" hidden></div>
        <div class="note"></div>
        <div class="actions">
          <button class="keep" aria-pressed="${answer.verdict === "keep"}">Keep</button>
          <button class="fix" aria-pressed="${answer.verdict === "fix"}">Fix</button>
          <input aria-label="Correct number for ${item.id}" placeholder="Type the number as printed"
                 ${answer.verdict === "fix" ? "" : "hidden"}>
        </div>
      </div>`;
    if (item.number) el.querySelector(".stamp").textContent = item.number;
    const flag = el.querySelector(".flag");
    if (item.other) {
      flag.textContent = `Reader 2 read ${item.other}`;
      flag.hidden = false;
    } else if (item.number && !item.agreed) {
      flag.textContent = "The readers were unsure of a character";
      flag.hidden = false;
    }
    el.querySelector(".note").textContent = item.note;
    const input = el.querySelector("input");
    input.value = answer.number || "";
    el.querySelector(".keep").onclick = () => keep(i);
    el.querySelector(".fix").onclick = () => fix(i);
    input.onkeydown = (event) => {
      if (event.key === "Enter") { event.preventDefault(); saveFix(i); }
      if (event.key === "Escape") { input.blur(); }
    };
    el.onclick = (event) => { if (event.target.tagName !== "INPUT") select(i, false); };
    list.append(el);
  }
  select(firstOpen(), false);
  progress();
}

function firstOpen() {
  const i = items.findIndex((item) => !saved[item.id]);
  return i === -1 ? 0 : i;
}

function select(i, scroll = true) {
  current = Math.max(0, Math.min(items.length - 1, i));
  document.querySelectorAll("article.current").forEach((el) => el.classList.remove("current"));
  const el = document.getElementById(items[current].id);
  el.classList.add("current");
  if (scroll) el.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
}

function store(i, answer) {
  saved[items[i].id] = answer;
  localStorage.setItem("meter-check", JSON.stringify(saved));
  const el = document.getElementById(items[i].id);
  el.dataset.verdict = answer.verdict;
  el.querySelector(".keep").setAttribute("aria-pressed", answer.verdict === "keep");
  el.querySelector(".fix").setAttribute("aria-pressed", answer.verdict === "fix");
  el.querySelector("input").hidden = answer.verdict !== "fix";
  progress();
}

function keep(i) { store(i, { verdict: "keep", number: "" }); select(i + 1); }

function fix(i) {
  select(i, false);
  const input = document.getElementById(items[i].id).querySelector("input");
  input.hidden = false;
  input.focus();
}

function saveFix(i) {
  const input = document.getElementById(items[i].id).querySelector("input");
  if (!input.value.trim()) { input.placeholder = "Type the number, or press Escape and K to keep"; return; }
  store(i, { verdict: "fix", number: input.value.trim() });
  input.blur();
  select(i + 1);
}

function progress() {
  const done = items.filter((item) => saved[item.id]).length;
  document.getElementById("progress").textContent = `${done} of ${items.length} checked`;
}

document.addEventListener("keydown", (event) => {
  if (event.target.tagName === "INPUT" || event.metaKey || event.ctrlKey) return;
  const key = event.key.toLowerCase();
  if (key === "k") keep(current);
  else if (key === "f") { event.preventDefault(); fix(current); }
  else if (key === "arrowdown" || key === "j") { event.preventDefault(); select(current + 1); }
  else if (key === "arrowup") { event.preventDefault(); select(current - 1); }
});

document.getElementById("export").onclick = () => {
  const quote = (value) => `"${String(value).replaceAll('"', '""')}"`;
  const rows = [["id", "verdict", "number"]].concat(
    items.map((item) => [item.id, saved[item.id]?.verdict || "", saved[item.id]?.number || ""])
  );
  const blob = new Blob([rows.map((row) => row.map(quote).join(",")).join("\\n") + "\\n"],
                        { type: "text/csv" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = "meter-check-answers.csv";
  link.click();
};

render();
</script>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)
    sub.add_parser("build", help="write review.html and the crops").set_defaults(
        func=lambda a: build()
    )
    p_ingest = sub.add_parser("ingest", help="store the downloaded answers")
    p_ingest.add_argument("csv")
    p_ingest.set_defaults(func=lambda a: ingest(a.csv))
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
