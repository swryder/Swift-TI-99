// Swift 99/a
//
// CRTSettings.swift
// Tunable parameters for the monitor-mode CRT shader. Held as @Published
// values so SwiftUI controls and the Metal renderer share state. Only
// consulted in monitor mode; windowed mode bypasses the CRT path entirely.
//
// Conceptually the parameters split into four groups:
//   • Geometry: scanlines, aperture mask, vignette
//   • Electron beam: Gaussian beam-spot blur, vertical phosphor bleed, bloom
//   • Composite NTSC: luma/chroma split blur, false-color artifacts, fringing
//   • Color grading: hue, saturation, contrast, brightness (post-decode)

import Foundation
import SwiftUI
import Combine

final class CRTSettings: ObservableObject {
    /// Master toggle. When false the shader passes the source frame through
    /// unmodified (still goes through the Metal pipeline; just no effects).
    @Published var enabled: Bool = true

    // MARK: Geometry

    /// Brightness drop in the gap between scanlines. 0 = no scanlines.
    @Published var scanlineStrength: Float = 0.35

    /// Strength of the RGB slot-mask pattern (vertical RGB triads with
    /// alternating-row half-triad offset, brick-like). Replaces the older
    /// continuous-stripe aperture grille — slot mask is what 1979-era
    /// in-line-gun consumer monitors actually used. 0 = no mask.
    @Published var maskStrength: Float = 0.25

    /// Pincushion geometry distortion — corners of the picture pulled inward
    /// from a square. Characteristic of 90°-deflection in-line-gun CRTs of
    /// the late 1970s before digital geometry correction. 0 = flat geometry.
    @Published var pincushion: Float = 0.0

    /// Radial darken from the center. Useful range 0…0.5.
    @Published var vignette: Float = 0.15

    // MARK: Electron beam

    /// Gaussian width of the luma beam-spot blur, in source pixels (σ ∈ 0…1.4).
    /// Replaces the old flat 3-tap horizontal smear with a properly rolling-off
    /// kernel — the beam is brightest at center and tapers smoothly into
    /// neighbors, so dark pixels don't pick up a sharp 1-pixel rim of bright
    /// neighbor color.
    @Published var beamBlur: Float = 0.30

    /// Vertical bleed between adjacent scanlines, simulating phosphor decay.
    /// Subtler than horizontal blur because scanlines already structure the
    /// vertical axis. 0 = no vertical bleed.
    @Published var phosphorBleed: Float = 0.10

    /// Soft halo around near-white highlights. Mid-tone TI palette colors
    /// don't trigger bloom — only luminance ≳ 0.8. 0 = no bloom.
    @Published var bloomStrength: Float = 0.50

    // MARK: Composite NTSC

    /// Gaussian width of the chroma blur (σ ∈ 0.5…3 source pixels). Independent
    /// from `beamBlur`: in real composite video, color bandwidth is ~1.3 MHz
    /// while luma is ~3 MHz, so colors visibly bleed farther than brightness.
    @Published var colorBleed: Float = 0.40

    /// False-color generation on sharp luma edges, modulated by the chroma
    /// carrier phase. 4-pixel period — produces the characteristic "rainbow"
    /// fringe that some TI software (e.g. Parsec) deliberately exploited.
    @Published var artifacts: Float = 0.10

    /// Brightness shimmer on chroma edges. Inverse of `artifacts`: chroma
    /// bleeding into the luma path during composite decode.
    @Published var fringing: Float = 0.10

    // MARK: Color grading (post-decode)

    /// Hue rotation of the (I, Q) chroma vector. ±1 → ±π (full color wheel).
    @Published var hue: Float = 0.0

    /// Chroma saturation scale. 0 = neutral; +1 doubles saturation; −1 grayscale.
    @Published var saturation: Float = 0.0

    /// Contrast scale around 0.5. 0 = neutral; +1 doubles contrast.
    @Published var contrast: Float = 0.0

    /// Brightness offset added to RGB. ±1 = ±100% brightness. 0 = neutral.
    @Published var brightness: Float = 0.0

    /// Strength of the P22 phosphor color matrix — blends between identity
    /// (sRGB-ideal) and an approximation of the cross-channel contamination
    /// real P22 phosphors produced. Slight cool-white tint on whites,
    /// slightly impure primaries. 0 = pure sRGB; 1 = full P22 character.
    @Published var phosphor: Float = 0.0
}
