import io

from PIL import Image

from panel_eval.screen import tally
from panel_eval.sources import MAX_WIDTH, REUSABLE_COMMONS, save_upright


def row(dup="", m="0", s="0", a="0"):
    return {"duplicate_of": dup, "manufacturer": m, "model": s, "amperage": a}


def test_tally_counts_each_photo_once_and_nests_the_criteria():
    rows = [
        row(m="1", s="1", a="1"),
        row(dup="p01", m="1", s="1", a="1"),  # a second copy of the first photo
        row(m="1", a="1"),
        row(a="1"),
        row(),
    ]
    assert tally(rows) == {
        "examined": 4,
        "any field legible": 3,
        "manufacturer and (model or amperage)": 2,
        "all three": 1,
    }


def test_commons_license_filter_accepts_only_reusable_licenses():
    for ok in ("CC0", "Public domain", "PD-USGov", "CC BY 2.0", "CC BY-SA 4.0"):
        assert REUSABLE_COMMONS.match(ok), ok
    for bad in ("GFDL", "CC BY-NC 2.0", "CC BY-ND 4.0", "Copyrighted", ""):
        assert not REUSABLE_COMMONS.match(bad), bad


def test_save_upright_applies_exif_rotation_and_caps_width(tmp_path):
    image = Image.new("RGB", (MAX_WIDTH * 2, 100), "white")
    exif = image.getexif()
    exif[0x0112] = 6  # stored rotated: display needs a 90 degree turn
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", exif=exif)
    dest = tmp_path / "out.jpg"
    save_upright(buffer.getvalue(), dest)
    with Image.open(dest) as saved:
        # Rotated to 100 x 7680, which is already under the width cap.
        assert saved.size == (100, MAX_WIDTH * 2)

    wide = io.BytesIO()
    Image.new("RGB", (MAX_WIDTH * 2, 100), "white").save(wide, format="JPEG")
    save_upright(wide.getvalue(), dest)
    with Image.open(dest) as saved:
        assert saved.size == (MAX_WIDTH, 50)
