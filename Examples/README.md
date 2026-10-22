# The VeilGarde examples

One program, read top to bottom, that runs VeilGarde's two lanes on this Mac and checks itself against VeilGarde's own goldens:

0. **Metal and the bundle.** MLX's Metal library beside the binary; the shipped bundle verified against its manifest.
1. **The images.** The two parity crops VeilGarde's goldens hold, and, when `final_mixed` is under `VEILGARDE_DATASETS` (or the work area's `datasets/`), six iPhone originals and six generated images from it, every k-th by name.
2. **Capture.** The native Nyquist peak, present at 30 or more when the short side reaches 512, and the screenshot gate.
3. **Semantics.** DINOv2-small's two readings of the same image, 384 numbers each: the plain one the camera head reads and the force-resized one the linear heads read.
4. **Camera.** The 393-column camera row built by hand, DINOv2's 384 then the nine capture values, and the camera head's P(AI).
5. **The stack.** Every member of the stack with its own P(AI) and verdict, every revision and what it did, the combiner revision's arithmetic term by term, and the result against VeilGarde's goldens.
6. **Training, in miniature.** A `TrainingRecipe` written in Swift (a warm start on the shipped camera head, the human head, the combiner), its plan, and the engine's run into a candidate bundle in `Examples/.work/candidates/examples`, on a seeded sample of the work area's feature store, three columns a row. Without the store, seeded synthetic rows stand in, and the step says so.
7. **The flywheel.** The regime alone, in `Examples/.work`: the shipped bundle copied as the live bundle, a regression battery (every image keeps the call the shipped detector gives it, as HARD groups), a frozen weight and a retired slot refused, the human head from step 6 promoted behind its admission gate and the battery, the promote log, and a rollback.
8. **The watermark.** The first parity crop signed by its own fragility pattern (four ordinal bits a tile, sectioned 4×4), matched against itself, then a half-area crop at a seeded random offset found by the phase search, and a JPEG q75 re-encode; the crop and the re-encode are reported, not asserted.
9. **Verify.** Every checkpoint; the exit code is 0 only when all hold.

## Run

```sh
scripts/cli.sh weights import-dinov2   # once: DINOv2's weights into the work area
Examples/run.sh                      # builds release, installs mlx.metallib, runs
```

The first build compiles Frigate's MLX and takes minutes. From Xcode, open `Examples/Package.swift` and Run; step 0 copies a staged `mlx.metallib` beside Xcode's binary.

## What the checkpoints compare

- The camera row built by hand gives the camera member's P(AI).
- The combiner computed by hand equals the combiner revision's P(AI).
- The result matches VeilGarde's golden for each crop with every label exact and every number within 1e-4; DINOv2's matrix kernels move with Frigate's MLX revision by about 1e-5.
- The warm start keeps the shipped camera head's 500 trees byte for byte and adds two.
- The candidate's camera head reads back through Frigate's evaluator with identical predictions on the store sample's rows.
- The candidate bundle verifies: every artifact's hash matches its manifest.
- Promote refuses a frozen weight and a retired slot.
- The frozen weights never move, and after the promote and its rollback the live bundle is byte for byte what it was.
- The watermarked image matches its own signature at offset (0, 0) with score 1.

On 2026-10-21 every one of the 12 checkpoints held. It writes nothing outside `Examples/.work` (gitignored), and only from step 6 on. Run the candidate it trains with
`scripts/cli.sh route <image> --bundle Examples/.work/candidates/examples`, and look at its flywheel with
`scripts/cli.sh flywheel status --work-area Examples/.work`.
