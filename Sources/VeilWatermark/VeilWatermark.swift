//
//  VeilWatermark.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A passive, crop-robust signature read off an image's per-tile warp fragility pattern:
//        sectioned tile codes that a crop of the same image reproduces, matched by offset and
//        grid phase. Re-exports the Lens, whose residual it reuses rather than forks.
//

@_exported import VeilGardeLens
