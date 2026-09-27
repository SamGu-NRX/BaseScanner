# Resources used on the shared Mac (M4 Pro, 24 GB)

Peak resident memory is from `/usr/bin/time -l` on each command. GPU memory on Apple silicon is unified and is not counted in resident memory, so the MPS figure comes from `torch.mps.driver_allocated_memory()`.

| Step | Command | Wall time | Peak RSS |
|---|---|---|---|
| Select Open Images metadata (streamed, about 1.7 GB read per run, run twice) | `python -m autodetect.openimages select` | 111 s | 152 MB |
| Download and downscale 1,790 Open Images photos | `python -m autodetect.openimages download` | 127 s | 161 MB |
| Vision rectangles, all sets | `python -m autodetect.run_vision` | 8 s | 79 MB |
| OWLv2 on MPS, 828 images | `python -m autodetect.owl` | 488 s | 1.50 GB |
| OWLv2 onnxruntime CPU probe (fp16; fp32 upcast) | one image, three runs | 43 s; 82 s | 1.96 GB; 1.77 GB |
| Laser elevations for door ground truth | `python -m autodetect.extent_gt render` | under 60 s | 590 MB |
| Create ML, Create ML's own iteration count (stopped by me after 2 h 8 min, no progress output) | first `trainod` | 7,706 s | 323 MB |
| Create ML, 1,000 iterations | `python -m autodetect.student train transfer 1000` | 556 s | 478 MB |
| Create ML student inference, all sets plus CPU-only pass | `python -m autodetect.student predict transfer scaleFill` | 136 s | 293 MB |
| Grounding DINO onnxruntime CPU probe | one image, three runs | 82 s | 2.73 GB |
| D-FINE small training probe, 20 steps | `python -m autodetect.dfine probe` | 187 s | 361 MB RSS plus 3.56 GB MPS |

Load averages on the 12-core Mac ranged from 18 to 492 during the run, because other agents shared it. Every timing above and in `proposals.md` is slower than on an idle machine by an unknown factor.

## Disk

- `~/house-scanning-data/autodetect/` holds 289 MB at the end: Open Images 206 MB, CMP 42 MB, cached predictions 28 MB, the Create ML model and hard links to its training images, and small files.
- The folder peaked at about 960 MB between 21:36 and 21:52. The Grounding DINO weights (360 MB) were still on disk when Create ML's session folder (230 MB, checkpoints I did not expect) was written. That peak exceeded the 900 MB limit. Both folders are now deleted, along with an 85 MB cache of the scan in the meter frame, which `extent_gt` rebuilds.
- Weights were deleted after their predictions were cached: OWLv2 (308 MB), Grounding DINO (360 MB) and D-FINE small (41 MB). Their configuration and tokenizer files (under 3 MB) remain.
- `experiments/autodetect/.venv` shows 869 MB under `du`. uv clones files from its cache on APFS, so most of that is shared: free space dropped about 55 MB when torch 2.14.0 and transformers were added.
- `swift build` writes a 370 MB `.build` folder. It was deleted after each build, and the three binaries (under 400 KB) live in `~/house-scanning-data/autodetect/bin/`.
