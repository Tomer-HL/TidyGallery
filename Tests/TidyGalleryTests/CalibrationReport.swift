//
//  CalibrationReport.swift
//  TidyGalleryTests
//
//  Calibration moved OUT of the iOS test target.
//
//  Reason: `VNGenerateImageFeaturePrintRequest` does not run on the iOS
//  Simulator — it returns near-constant embeddings, so every photo looks
//  identical and the distances are meaningless. Face detection and sharpness
//  work on the simulator, but the feature-print model does not.
//
//  Calibration now lives in the `CalibrationTool` macOS command-line target
//  (see CalibrationTool/main.swift), which runs the real model natively on the
//  CI Mac. See the README's "Calibrating the thresholds" section.
//
//  This file is intentionally left as documentation only.
//
