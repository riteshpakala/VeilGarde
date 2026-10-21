[![VeilGarde: one verdict, and a signature that survives a crop. An image's 16 by 16 tiles, coloured by how generated each reads and lit by its fragility, feed two lanes: above, the fusion base and the stacked verdict, ending in a gold mark; below, sixteen warps and the signature's id, ending in a square.](README_Assets/hero.png)](README_Assets/hero.png)

# VeilGarde

VeilGarde is a detector for AI-generated images, with a crop-robust watermark, as one Swift package you can train and run on a Mac. [Veil](https://veil.rao.nyc) is the pipeline, [Veil8](https://github.com/riteshpakala/Veil8) the PPM, VeilGarde the detection and watermarking.

It runs in two lanes.

**Detection.** A **fusion head** reads what an image depicts, from a frozen DINOv2 embedding, and whether a camera captured its pixels, from the **capture signature** measured at native resolution. Its probability is the base. **Specialist heads** for art, blur, faces, previews and screenshots then add their evidence under a small non-negative **stacked combiner**, two mechanisms revise it only on decisive evidence, and one verdict comes out. A **flywheel** trains and improves the fusion head and the specialist stack from a store of features, without ever storing an image.

**The watermark.** Every 32×32 tile of an image is perspective-warped through 16 fixed homographies and back. A camera sensor's mosaic and noise do not survive the round trip the way a generator's output does. Each tile's **fragility**, how much more of it the stronger warp loses, becomes four ordinal bits against its neighbours. The signature adds nothing to the pixels, and a crop or a re-encode is matched against it.

| Subpackage | Holds |
|---|---|
| `VeilGardeCore` | the domain, with no MLX: the fusion row, the XGBoost codec, heads and the combiner, bundles, the result JSON, the feature store |
| `VeilGardeLens` | the extractors: capture, DINOv2, CLIP, and the boosted-tree evaluator |
| `VeilGardeInference` | the detector: the fusion base, the specialist stack, the router, the verdict |
| `VeilGardeTraining` | the trainers for the fusion head, the heads and the combiner, driven by a recipe DSL, and the backbone imports |
| `VeilGardeFlywheel` | acquisition into a features-only store, candidates, the battery, promote and rollback |
| `VeilWatermark` | the warp residual and a crop-robust signature read off each tile's fragility |
| `veilgarde` | the CLI over all of it |

## Detection accuracy

**v1** is the shipped two lanes: the fusion head over DINOv2 and the capture signature, then the specialist stack. Its battery, spec v3, passes on 96 images and is the baseline for testing; four generated images it misses are set aside for research. Measured on 2026-10-21. A real image counts as right when it's called real; a generated image when it's called generated. "Inconclusive" counts as wrong.

| Detector | Real, final_mixed census | Generated, final_mixed census | Real, unseen final_mixed | Generated, unseen final_mixed | Real, iPhone originals |
|---|---|---|---|---|---|
| **v1**, shipped: fusion head + stack | 95% | 41% | 90.0% | 34.5% | 99.3% |
| Residual head, in-sample combiner | 97% | 91% | 85.3% | 56.6% | 99.8% |
| Residual head, out-of-fold combiner | 97% | 89% | 87.6% | 52.0% | 99.8% |
| The warp era, for reference | 91% | 70% | not measured | not measured | 99.8% |

- **Census:** 100 real and 100 generated final_mixed images. Most of them are rows the fusion heads trained on, so these columns read high.
- **Unseen:** the 3,217 final_mixed images in no store shard (1,602 real, 1,615 generated). This is the honest measure.
- **iPhone originals:** 438 camera photos, all real.
- **Residual head:** both DINOv2 readings, capture and the warp residual's statistics, 815 columns, 1,000 trees of depth 7.

## The CLI at a glance

```sh
scripts/cli.sh doctor                                   # builds veilgarde, installs MLX's Metal library, checks the setup
scripts/cli.sh route photo.jpg                          # the full detector: domain, verdict, base, capture, the stack
scripts/cli.sh route photo.jpg --json                   # the same, as the schema-v3 result
scripts/cli.sh train plan --preset                      # what the shipped recipe would train, without training
VEILGARDE_CONFIG=release scripts/cli.sh train heads     # a candidate bundle under <work area>/candidates/
scripts/cli.sh flywheel init && scripts/cli.sh flywheel battery --gate full
VEILGARDE_CONFIG=release scripts/cli.sh research census  # every call of a bundle on the battery and 200 labelled images
scripts/cli.sh watermark sign photo.jpg > photo.vw1 && scripts/cli.sh watermark match crop.jpg photo.vw1
```

`scripts/cli.sh` builds `veilgarde`, installs `mlx.metallib` beside it, and finds Frigate. `scripts/cli.sh <command> --help` lists a command's flags.

## The playground

[Playground/](Playground/README.md) runs both regimes on this Mac in one program and exits 0 only when every checkpoint holds: one image's capture signature and DINOv2 embeddings, the fusion base built by hand, the specialist stack and the combiner's arithmetic term by term, then each trainer in miniature, the flywheel's promote and rollback, and the watermark. [The site's chapter 9](docs/site/09-playground.html) walks through it.

```sh
Playground/run.sh
```

## VeilGarde docsite

A site that explains each layer and shows every file this build changed, verbatim, with each Swift declaration's calls and callers, and the run's ledger of commands, tests and decisions. Eleven trails walk the code in the order it runs: how the fusion head and the specialist stack are trained, detection stage by stage from Decode through Shared Signals, Domain, Base, Stack and Revisions to Result, and how the watermark signs an image and matches a crop of it. A grid picks them, a row for each flow and a column for each kind. Double-click scripts/site.command, or open [docs/site/index.html](docs/site/index.html); it is plain HTML with no build step. [docs/site/README.md](docs/site/README.md) says how it is rebuilt and checked.

The site's chat asks Mistral about what you are reading. On a Mac that holds a Mistral key in its key store, `scripts/site.command` hands the site that key; anyone else is asked for their own key in a dialog when the chat opens, and it stays in their browser.

## Requirements and tests

- Xcode 27 (Swift 6.4), macOS 26, Apple silicon.
- [Frigate](https://github.com/rao-studios/Frigate), the family's MLX stack, checked out beside this repo or named by `VEILGARDE_FRIGATE_DIR`.
- A work area, the folder `VEILGARDE_WORK_AREA` (or `--work-area`) names: the live bundle, the weights, the feature store, candidates and the battery. VeilGarde writes nowhere else. Datasets live under `VEILGARDE_DATASETS`, else the work area's `datasets/`.
- The weights, in the work area's `weights/`: `veilgarde weights import-dinov2` builds DINOv2's from Hugging Face's checkpoint, and `veilgarde weights import-clip` CLIP's vision tower for acquisition.
- Tests: `swift build --build-tests`, then `./build-metallib.sh debug` to put MLX's Metal library into the test bundles, then `VEILGARDE_MLX_TESTS=1 swift test --skip-build --no-parallel` (without `VEILGARDE_MLX_TESTS`, only the CPU suites run). Before the next test build, delete the `mlx.metallib` copies inside `.build`'s `.xctest` bundles: a bundle that holds one fails to re-sign.

Inside each target, folders follow the order of operations. The site's chapters walk them, and its change explorer shows every file.

## Where it came from

VeilGarde consolidates the detector's research into one tool. It was ported from Garde on 2026-10-19, ([CLR](https://rao.nyc/thoughts/2026-04-25), [CLR (Journey)](https://paka.la/blog/clr-journey)), the R&D it supersedes, and its trainers reproduce the research's Python recipes, whose numbers it quotes with their dates. On 2026-10-21 it was cut to its two lanes: the warp model, its calibration, the noiseprint and the reduction studies left the detector, and the code before the cut lives on the `2026-rnd` branch. It takes MLX from Frigate, and its layout, recipes, docs site and explorer from Braid.

GNU General Public License v3.0 (see [LICENSE](LICENSE)).
