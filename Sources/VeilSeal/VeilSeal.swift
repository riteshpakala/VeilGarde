//
//  VeilSeal.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A passive, crop-robust signature read off an image's per-tile warp fragility pattern:
//        sectioned tile codes that a crop of the same image reproduces, matched by offset and
//        grid phase. The warp residual it reads is its own (Residual/); it re-exports the Lens for
//        decoding and image handling. Beside it, the pixel mark (vgm1): an id written into the same
//        fragility and read blind (Mark/, BurgundySeal its one door), the records a store keeps (Store/),
//        and the pictures that show a mark (Render/).
//

@_exported import VeilGardeLens
