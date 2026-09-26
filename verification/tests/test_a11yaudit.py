from hsverify.a11yaudit import parse_output, symbol_name_labels


def test_parse_output_reads_screens_and_issues_and_skips_noise():
    text = "\n".join(
        [
            "Test Case started.",
            'A11Y_ISSUE={"screen": 2, "description": "Hit area is too small"}',
            'A11Y_SCREEN={"index": 2, "labels": ["text:hi"], "issues": 1}',
            "A11Y_SCREEN={broken",
        ]
    )
    screens, issues = parse_output(text)
    assert screens == [{"index": 2, "labels": ["text:hi"], "issues": 1}]
    assert issues == [{"screen": 2, "description": "Hit area is too small"}]


def test_symbol_name_labels():
    screens = [
        {
            "index": 1,
            "labels": [
                "button:gearshape",
                "button:arrow.left.circle.fill",
                "button:camera",
                "button:I'm here",
                "text:xmark",
            ],
        }
    ]
    assert symbol_name_labels(screens) == [
        {"screen": 1, "label": "gearshape"},
        {"screen": 1, "label": "arrow.left.circle.fill"},
    ]
