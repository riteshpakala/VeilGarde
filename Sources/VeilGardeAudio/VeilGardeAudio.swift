//
//  VeilGardeAudio.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The watermark's second carrier: a clip becomes its spectrogram picture, the picture is
//        signed and matched by the watermark unchanged, and the picture goes back to audio. Nothing
//        is written into the sound. It re-exports VeilWatermark, which re-exports the Lens and Core.
//

@_exported import VeilWatermark
