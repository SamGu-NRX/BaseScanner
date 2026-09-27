from autodetect.cmp import parse

XML = (
    "<object>\r<points>\r<x>\r0.2\r</x>\r<x>\r0.3\r</x>\r<y>\r0.6\r</y>\r<y>\r0.5\r</y>\r</points>\r"
    "<label>\r3\r</label>\r<labelname>\rwindow\r</labelname>\r<flag>\r1\r</flag>\r</object>\r"
    "<object>\r<points>\r<x>\r0\r</x>\r<x>\r1\r</x>\r<y>\r0\r</y>\r<y>\r1\r</y>\r</points>\r"
    "<label>\r2\r</label>\r<labelname>\rfacade\r</labelname>\r<flag>\r1\r</flag>\r</object>\r"
)


def test_x_tags_are_rows_and_y_tags_are_columns(tmp_path):
    f = tmp_path / "cmp_b9999.xml"
    f.write_text(XML)
    assert parse(f) == [{"label": "window", "box": [0.5, 0.2, 0.6, 0.3], "group": False}]
