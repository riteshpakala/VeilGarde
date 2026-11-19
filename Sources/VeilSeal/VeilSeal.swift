//
//  VeilSeal.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The Burgundy Seal: "pixels may change, but neighbourhoods rarely do". A picture's anchors
//        (Anchor/: scale-space extrema, their canonical squares, keyed patterns (phase by default;
//        hsl, structure, census) and the warp residual at each), the paths their patterns walk (Path/: walking, matching, consensus, retracing), and the
//        signature a store keeps (Seal/: burgundy/1, SealStore, BurgundySeal its one door). Beside it,
//        the grid signature (vw1: Residual/, Signature/, Sections/, Match/), the pixel mark (vgm1, Mark/)
//        that interlaces a seal's id until the anchor interlace passes its bars, and the pictures that
//        show a seal (Render/: the wax seal, the digest, the detection graphic). It re-exports the Lens
//        for decoding and image handling.
//

@_exported import VeilGardeLens
