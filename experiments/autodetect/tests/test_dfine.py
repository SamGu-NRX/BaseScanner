import pytest

torch = pytest.importorskip("torch")
from transformers import DFineConfig  # noqa: E402
from transformers.models.d_fine.modeling_d_fine import DFineIntegral  # noqa: E402

from autodetect.dfine import _integral_forward  # noqa: E402


def test_patched_integral_matches_transformers():
    cfg = DFineConfig()
    layer = DFineIntegral(cfg)
    g = torch.Generator().manual_seed(0)
    corners = torch.randn(2, 5, 4 * (cfg.max_num_bins + 1), generator=g)
    project = torch.randn(cfg.max_num_bins + 1, generator=g)
    expected = DFineIntegral.forward(layer, corners, project)
    assert torch.allclose(_integral_forward(layer, corners, project), expected, atol=1e-6)
