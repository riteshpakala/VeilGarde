[![VeilGarde: one verdict, and a signature that survives a crop. An image's 16 by 16 tiles, coloured by how generated each reads and lit by its fragility, feed two lanes: above, the stack's members and the combined verdict, ending in a gold mark; below, sixteen warps and the signature's id, ending in a square.](README_Assets/hero.png)](README_Assets/hero.png)

# VeilGarde

VeilGarde is a detector for AI-generated images, with a crop-robust watermark, as one Swift package you can train and run on a Mac. [Veil](https://veil.rao.nyc) is the pipeline, [Veil8](https://github.com/riteshpakala/Veil8) the PPM, VeilGarde the detection and watermarking.

It runs in two lanes.

**Detection** is five stages: Decode, Shared Signals, Stack, Revisions, Result. The **stack** is a flat list of independent members, each with its own score:

- the **camera head**, reading what an image depicts, from a frozen DINOv2 embedding, and whether a camera captured its pixels, from the **capture signature** measured at native resolution;
- the screenshot gate and its content head;
- the capture signature itself;
- **specialist heads** for art, blur, faces and previews;
- the semantic tiles.

Three **revisions** read them. A small non-negative **combiner** anchors on the camera head, or on the screenshot head when the gate fires, and pools the specialists' evidence; the frame seam and the preview tail act only on decisive evidence. The result lists every member's score. A **flywheel** trains and improves the members from a store of features, without ever storing an image. Inference and training are declared the same way, so a new member is one file and one line on each side.

**The watermark.** Every 32×32 tile of an image is perspective-warped through 16 fixed homographies and back. A camera sensor's mosaic and noise do not survive the round trip the way a generator's output does. Each tile's **fragility**, how much more of it the stronger warp loses, becomes four ordinal bits against its neighbours. The signature adds nothing to the pixels, and a crop or a re-encode is matched against it.

| Subpackage | Holds |
|---|---|
| `VeilGardeCore` | the domain, with no MLX: the camera row, the XGBoost codec, heads and the combiner, bundles, the schema-v1 result, the feature store and its migration |
| `VeilGardeLens` | the extractors: capture, DINOv2, CLIP, and the boosted-tree evaluator |
| `VeilGardeInference` | the detector as one pipeline: the shared signals, the stack's members, the revisions, the result |
| `VeilGardeTraining` | the trainers for the camera head, the heads and the combiner, declared as trainable members in a recipe DSL that mirrors the pipeline, and the backbone imports |
| `VeilGardeFlywheel` | acquisition into a features-only store, candidates, the battery, promote and rollback |
| `VeilWatermark` | the warp residual and a crop-robust signature read off each tile's fragility |
| `veilgarde` | the CLI over all of it |

## Detection as a declaration

The detector is one Swift value. Its shape in the code is its architecture: what reads the image, in what order, and what decides.

```swift
public static var v1: Pipeline {
    Pipeline {
        Stack {
            Screenshot()
            Camera()
            Capture()
            Specialist(.art)
            Specialist(.blur)
            Specialist(.human)
            Specialist(.preview)
            SemanticTiles()
        }
        Revisions {
            Combine()
            FrameSeam()
            PreviewTail()
        }
    }
}
```

An image moves through five stages:

1. **Decode** reads the file the one way every model was trained on.
2. **Shared Signals** computes what every member reads, once: the screenshot gate, the capture measurement, two DINOv2 readings and the patch tokens.
3. **Stack** asks every member for its own take. A member reads only the shared signals, never another member, and reports its own P(AI), its verdict and what it measured.
4. **Revisions** read the stack in order. The combiner sets the verdict around one anchor; the frame seam and the preview tail change it only on decisive evidence.
5. **Result** keeps the verdict beside every member's score and every revision's record, as schema-v1 JSON.

Training is declared the same way. The recipe lists the trainable members, and the engine trains each in dependency order without knowing any by name:

```swift
TrainingRecipe(id: "weekly") {
    CameraHead().warmStart(add: 80, eta: 0.03)
    for kind in HeadKind.flywheelCategories { SpecialistHead(kind) }
    Combiner()
}
```

That symmetry is what makes the engine iterative. A new detector for a new kind of generated image is a new member:

1. one file that conforms to `StackMember`, a name and `score(_:)` from the shared signals to its own output, and one line in the `Stack`;
2. if it learns from data, one file that conforms to `TrainableMember` and one line in the recipe;
3. if the verdict should weigh it, its name in the combiner's file, which a refit writes.

Nothing else changes. The new member's score appears in every result from its first run, so it is measured on its own and inside the verdict before anyone decides to trust it. The flywheel then grows it like the others: it finds where the stack is wrong, fetches images of that kind, keeps only their features, trains candidates and promotes one only behind the battery.

DINOv2 and the capture measurement run on the GPU through MLX, by way of [Frigate](https://github.com/rao-studios/Frigate); every trainer runs on the CPU from stored features, so a retrain never touches an image. The pipeline took this shape on 2026-10-21, and no verdict or score moved in the change.

## Detection accuracy

> **Work in progress.** The dataset, the training regime and the golden anchors are being revised, with the aim of raising accuracy on generated images to 80% in the coming weeks. The numbers below are v1's, measured on 2026-10-21, and will change as that work lands.

**v1** is the shipped detector: the camera head over DINOv2 and the capture signature, and the specialist members, pooled by the combiner. Its battery, `battery_spec.json` version 1, passes on 96 images and is the baseline for testing; four generated images it misses are set aside for research. Measured on 2026-10-21. The same day the stack became a list of members, and no number moved: the census calls before and after are identical. A real image counts as right when it's called real; a generated image when it's called generated. "Inconclusive" counts as wrong.

| Detector | Real, final_mixed census | Generated, final_mixed census | Real, unseen final_mixed | Generated, unseen final_mixed | Real, iPhone originals |
|---|---|---|---|---|---|
| **v1**, shipped: camera head + stack | 95% | 41% | 90.0% | 34.5% | 99.3% |
| Residual head, in-sample combiner | 97% | 91% | 85.3% | 56.6% | 99.8% |
| Residual head, out-of-fold combiner | 97% | 89% | 87.6% | 52.0% | 99.8% |
| The warp era, for reference | 91% | 70% | not measured | not measured | 99.8% |

- **Census:** 100 real and 100 generated final_mixed images. Most of them are rows the camera heads trained on, so these columns read high.
- **Unseen:** the 3,217 final_mixed images in no store shard (1,602 real, 1,615 generated). This is the honest measure.
- **iPhone originals:** 438 camera photos, all real.
- **Residual head:** both DINOv2 readings, capture and the warp residual's statistics, 815 columns, 1,000 trees of depth 7. It did not ship, and its code left on 2026-10-21; its rows are the record.

## The CLI at a glance

```sh
Scripts/cli.sh doctor                                   # builds veilgarde, installs MLX's Metal library, checks the setup
Scripts/cli.sh route photo.jpg                          # the full detector: the verdict, every member's score, every revision
Scripts/cli.sh route photo.jpg --json                   # the same, as the schema-v1 result
Scripts/cli.sh train plan --preset                      # what the shipped recipe would train, without training
VEILGARDE_CONFIG=release Scripts/cli.sh train heads     # a candidate bundle under <work area>/candidates/
Scripts/cli.sh flywheel init && Scripts/cli.sh flywheel battery --gate full
VEILGARDE_CONFIG=release Scripts/cli.sh research census  # every call of a bundle on the battery and 200 labelled images
Scripts/cli.sh watermark sign photo.jpg > photo.vw1 && Scripts/cli.sh watermark match crop.jpg photo.vw1
```

`Scripts/cli.sh` builds `veilgarde`, installs `mlx.metallib` beside it, and finds Frigate. `Scripts/cli.sh <command> --help` lists a command's flags.

## Examples

[Examples/](Examples/README.md) runs both regimes on this Mac in one program and exits 0 only when every checkpoint holds: one image's capture signature and DINOv2 embeddings, the camera head's row built by hand, every member of the stack and the combiner revision's arithmetic term by term, then each trainer in miniature, the flywheel's promote and rollback, and the watermark. [The site's chapter 9](Docs/site/09-examples.html) walks through it.

```sh
Examples/run.sh
```

## VeilGarde docsite

A site that explains each layer and shows every file this build changed, verbatim, with each Swift declaration's calls and callers, and the run's ledger of commands, tests and decisions. Nine trails walk the code in the order it runs: how the camera head and the specialist stack are trained, detection stage by stage from Decode through Shared Signals, Stack and Revisions to Result, and how the watermark signs an image and matches a crop of it. A grid picks them, a row for each flow and a column for each kind. Double-click Scripts/site.command, or open [Docs/site/index.html](Docs/site/index.html); it is plain HTML with no build step. [Docs/site/README.md](Docs/site/README.md) says how it is rebuilt and checked.

The site's chat asks Mistral about what you are reading. On a Mac that holds a Mistral key in its key store, `Scripts/site.command` hands the site that key; anyone else is asked for their own key in a dialog when the chat opens, and it stays in their browser.

## Requirements and tests

- Xcode 27 (Swift 6.4), macOS 26, Apple silicon.
- [Frigate](https://github.com/rao-studios/Frigate), the family's MLX stack, checked out beside this repo or named by `VEILGARDE_FRIGATE_DIR`.
- A work area, the folder `VEILGARDE_WORK_AREA` (or `--work-area`) names: the live bundle, the weights, the feature store, candidates and the battery. VeilGarde writes nowhere else. Datasets live under `VEILGARDE_DATASETS`, else the work area's `datasets/`.
- The weights, in the work area's `weights/`: `veilgarde weights import-dinov2` builds DINOv2's from Hugging Face's checkpoint, and `veilgarde weights import-clip` CLIP's vision tower for acquisition.
- Tests: `swift build --build-tests`, then `./build-metallib.sh debug` to put MLX's Metal library into the test bundles, then `VEILGARDE_MLX_TESTS=1 swift test --skip-build --no-parallel` (without `VEILGARDE_MLX_TESTS`, only the CPU suites run). Before the next test build, delete the `mlx.metallib` copies inside `.build`'s `.xctest` bundles: a bundle that holds one fails to re-sign.

Inside each target, folders follow the order of operations. The site's chapters walk them, and its change explorer shows every file.

## Where it came from

VeilGarde consolidates the detector's research into one tool. It was ported from Garde on 2026-10-19, ([CLR](https://rao.nyc/thoughts/2026-04-25), [CLR (Journey)](https://paka.la/blog/clr-journey)), the R&D it supersedes, and its trainers reproduce the research's Python recipes, whose numbers it quotes with their dates. On 2026-10-21 it was cut to its two lanes: the warp model, its calibration, the noiseprint and the reduction studies left the detector, and the code before the cut lives on the `2026-rnd` branch. The same day the detector became a stack of independent members with one DSL on both sides, and the goldens, the battery and the census did not move. It takes MLX from Frigate, and its layout, recipes, docs site and explorer from Braid.

GNU General Public License v3.0 (see [LICENSE](LICENSE)).
