# The VeilGarde playground

One program, read top to bottom, that runs VeilGarde on this Mac and checks itself against Garde:

0. **Metal and the bundle.** MLX's Metal library beside the binary; the shipped bundle verified against its manifest.
1. **The images.** The two parity crops Garde scored on 2026-10-19, and, when `final_mixed` is under `VEILGARDE_DATASETS` (or the work area's `datasets/`), six iPhone originals and six generated images from it, every k-th by name.
2. **The warp lens.** One image cut into 32-px tiles, each warped through 16 fixed homographies and back; the centre tile's 19 features by name.
3. **The camera-sensor score.** The warp tile model alone: P(generated) per tile, the tile vote, and the two cuts that call it (real at or under 0.7169 of the tiles, generated at or over 0.8365), with the call's trust; the weighted warp score at 0.56 ± 0.04. Then the same score on the iPhone and generated sample.
4. **Capture.** The native Nyquist peak and the screenshot gate.
5. **Fusion.** The 397-column vector and the fusion head's base P(AI).
6. **The specialists.** The full detector's stack, the combiner's arithmetic term by term, and the routed result against Garde's goldens.
7. **Training, in miniature.** A `TrainingRecipe` written in Swift (a toy warp tile model, a warm start on the shipped fusion head, the human head, the combiner), its plan, and the engine's run into a candidate bundle in `Playground/.work/candidates/playground`. The toy warp model trains on the final_mixed sample's tiles, cut by the warp lens; the heads and the combiner train on a seeded sample of the work area's feature store when this Mac has it. Without that sample or that store, seeded synthetic tiles and rows stand in, and the step says so. Its calibration is fitted by hand, since a dozen images are below the engine's floors of 25 and 15 per class, and said as two cuts on the vote, as the engine writes it.
8. **The flywheel.** The specialist regime alone, in `Playground/.work`: the shipped bundle copied as the live bundle, a regression battery (every image keeps the call the shipped detector gives it, as HARD groups), the frozen warp tile model refused, the human head from step 7 promoted behind its admission gate and the battery, the promote log, and a rollback.
9. **The watermark.** The first parity crop signed by its own fragility pattern (four ordinal bits a tile, sectioned 4×4), matched against itself, then a half-area crop at a seeded random offset found by the phase search, and a JPEG q75 re-encode; the crop and the re-encode are reported, not asserted.
10. **Verify.** Every checkpoint; the exit code is 0 only when all hold.

## Run

```sh
scripts/cli.sh weights import-dinov2   # once: DINOv2's weights into the work area
Playground/run.sh                      # builds release, installs mlx.metallib, runs
```

The first build compiles Frigate's MLX and takes minutes. From Xcode, open `Playground/Package.swift` and Run; step 0 copies a staged `mlx.metallib` beside Xcode's binary.

## What the checkpoints compare

- The warp lens's result JSON equals Garde's leaf for leaf, `times_sec` and the sensor fields the two cuts changed on purpose aside, and makes Garde's call.
- The routed result matches Garde's with every label exact and every number within 1e-4, the same sensor fields aside. Under Garde's own Metal library it was byte-identical (37 of 37 images, 2026-10-19, before the two cuts); under Frigate's current library DINOv2's matrix kernels move its outputs by about 1e-5.
- The combiner computed by hand equals the router's pre-semantic score.
- The toy warp model, written as XGBoost JSON, reads back through Frigate's evaluator with identical predictions on every tile.
- The toy calibration contract binds to the toy model's bytes and refuses the shipped model's.
- The warm start keeps the shipped fusion head's 940 trees byte for byte and adds two.
- The candidate bundle verifies: every artifact's hash matches its manifest.
- Promote refuses the frozen warp tile model.
- The watermarked image matches its own signature at offset (0, 0) with score 1.
- After the promote and its rollback (or a refused promote), the frozen artifacts' bytes are unchanged and the live bundle is byte for byte what it was.

It writes nothing outside `Playground/.work` (gitignored), and only from step 7 on. Run the candidate it trains with
`scripts/cli.sh route <image> --bundle Playground/.work/candidates/playground`, and look at its flywheel with
`scripts/cli.sh flywheel status --work-area Playground/.work`.
