// Swift 99/a
//
// CRTControlsView.swift
// Standalone tuning panel for the monitor-mode CRT shader. Sliders are bound
// directly to the same CRTSettings instance the Metal renderer reads, so
// adjustments take effect on the next frame. Hosted in a small fixed-size
// NSWindow opened from the View menu.
//
// Sliders are grouped into four sections that mirror the shader pipeline:
//   • Geometry      — scanlines, mask, vignette
//   • Electron Beam — beam blur (luma σ), phosphor bleed (vertical), bloom
//   • Composite NTSC— color bleed (chroma σ), artifacts, fringing
//   • Color         — hue, saturation, contrast, brightness (post-decode)

import SwiftUI
import AppKit

struct CRTControlsView: View {
    @ObservedObject var settings: CRTSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Master toggle + preset menu must stay enabled at all times,
                // otherwise turning effects off would leave the user with no
                // way to turn them back on.
                HStack {
                    Toggle("CRT Effects", isOn: $settings.enabled)
                        .toggleStyle(.switch)
                    Spacer()
                    Menu("Preset") {
                        Button("Off")              { applyPreset(.off) }
                        Button("Subtle")           { applyPreset(.subtle) }
                        Button("CRT")              { applyPreset(.crt) }
                        Button("Composite TV")     { applyPreset(.composite) }
                        Button("Original TI Monitor") { applyPreset(.originalTI) }
                        Button("Heavy")            { applyPreset(.heavy) }
                        Divider()
                        Button("Reset to Defaults") { applyPreset(.defaults) }
                    }
                    .fixedSize()
                }

                Divider()

                // Sliders are disabled while the master toggle is off, so they
                // visually reflect the inactive state without locking out the
                // toggle itself.
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Geometry")
                    slider("Scanlines",  $settings.scanlineStrength, 0...1)
                    slider("Slot Mask",  $settings.maskStrength,     0...1,
                           help: "Brick-pattern RGB triads with alternate-row " +
                                 "offset and a thin slot gap — what 1979 in-line-" +
                                 "gun consumer monitors actually used.")
                    slider("Pincushion", $settings.pincushion,       0...1,
                           help: "Edge-curvature distortion characteristic of " +
                                 "90°-deflection CRTs of the late 1970s. Picture " +
                                 "corners pull inward; out-of-frame areas go black.")
                    slider("Vignette",   $settings.vignette,         0...0.5)

                    sectionHeader("Electron Beam")
                    slider("Beam Blur", $settings.beamBlur, 0...1,
                           help: "Gaussian luma kernel width. Wider = softer " +
                                 "beam-spot. The center pixel always keeps the " +
                                 "most weight, so neighbors don't tint dark pixels.")
                    slider("Phosphor Bleed", $settings.phosphorBleed, 0...1,
                           help: "Vertical bleed between scanlines. Subtle by " +
                                 "default since scanlines already structure the " +
                                 "vertical axis.")
                    slider("Bloom", $settings.bloomStrength, 0...1,
                           help: "Soft glow on near-white highlights only. " +
                                 "Mid-tone TI palette colors do not bloom.")

                    sectionHeader("Composite NTSC")
                    slider("Color Bleed", $settings.colorBleed, 0...1,
                           help: "Independent chroma blur. Real composite " +
                                 "color bandwidth (~1.3 MHz) is much narrower " +
                                 "than luma, so colors visibly spread farther " +
                                 "than brightness.")
                    slider("Artifacts", $settings.artifacts, 0...1,
                           help: "Phase-modulated false color on sharp luma " +
                                 "edges. Produces the rainbow fringe that some " +
                                 "TI software (Parsec) deliberately exploited.")
                    slider("Fringing", $settings.fringing, 0...1,
                           help: "Brightness shimmer on chroma edges — the " +
                                 "inverse of artifacts. Subtle.")

                    sectionHeader("Color")
                    bipolar("Hue",        $settings.hue)
                    bipolar("Saturation", $settings.saturation)
                    bipolar("Contrast",   $settings.contrast)
                    bipolar("Brightness", $settings.brightness)
                    slider("P22 Phosphor", $settings.phosphor, 0...1,
                           help: "Approximation of P22 phosphor character — " +
                                 "cool white tint, slightly impure primaries with " +
                                 "cross-channel contamination. 1979 monitor feel.")
                }
                .disabled(!settings.enabled)
            }
            .padding(14)
        }
        .frame(minWidth: 380, idealWidth: 400, minHeight: 480, idealHeight: 720)
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .default))
                .foregroundColor(.secondary)
                .tracking(0.5)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func slider(_ title: String,
                        _ value: Binding<Float>,
                        _ range: ClosedRange<Float>,
                        help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            Slider(value: value, in: range)
            if let help = help {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Bipolar slider for −1…+1 grading parameters. Same UI as `slider` but
    /// shows the sign in the readout and starts visually centered at 0.
    @ViewBuilder
    private func bipolar(_ title: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button {
                    value.wrappedValue = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Reset to 0")
            }
            Slider(value: value, in: -1...1)
        }
    }

    // MARK: - Presets

    private enum Preset { case off, subtle, crt, composite, originalTI, heavy, defaults }

    private func applyPreset(_ preset: Preset) {
        switch preset {
        case .off:
            settings.enabled = false

        case .subtle:
            settings.enabled          = true
            settings.scanlineStrength = 0.20
            settings.maskStrength     = 0.12
            settings.pincushion       = 0
            settings.vignette         = 0.08
            settings.beamBlur         = 0.18
            settings.phosphorBleed    = 0.05
            settings.bloomStrength    = 0.30
            settings.colorBleed       = 0.20
            settings.artifacts        = 0
            settings.fringing         = 0
            settings.hue              = 0
            settings.saturation       = 0
            settings.contrast         = 0
            settings.brightness       = 0
            settings.phosphor         = 0

        case .crt:
            settings.enabled          = true
            settings.scanlineStrength = 0.35
            settings.maskStrength     = 0.25
            settings.pincushion       = 0
            settings.vignette         = 0.15
            settings.beamBlur         = 0.30
            settings.phosphorBleed    = 0.10
            settings.bloomStrength    = 0.50
            settings.colorBleed       = 0.40
            settings.artifacts        = 0.10
            settings.fringing         = 0.10
            settings.hue              = 0
            settings.saturation       = 0
            settings.contrast         = 0
            settings.brightness       = 0
            settings.phosphor         = 0

        case .composite:
            // Lean into the composite-TV look: heavy chroma bleed, visible
            // rainbow artifacts on luma edges. Generic 1980s composite TV
            // rather than a specific monitor.
            settings.enabled          = true
            settings.scanlineStrength = 0.40
            settings.maskStrength     = 0.30
            settings.pincushion       = 0.05
            settings.vignette         = 0.18
            settings.beamBlur         = 0.40
            settings.phosphorBleed    = 0.15
            settings.bloomStrength    = 0.55
            settings.colorBleed       = 0.70
            settings.artifacts        = 0.40
            settings.fringing         = 0.30
            settings.hue              = 0
            settings.saturation       = 0.10
            settings.contrast         = 0.05
            settings.brightness       = 0
            settings.phosphor         = 0.30

        case .originalTI:
            // Approximation of the Panasonic BTS-1000N — the 10" composite
            // color monitor TI rebadged and shipped with the TI-99/4 in 1979.
            // Reasoning, from the service manual + period-typical specs:
            //   • 10" CRT, 192-line visible picture → strong scanlines.
            //   • In-line gun, 90° deflection, slot mask → brick-offset RGB
            //     triads, NOT a Trinitron-style aperture grille (that's a
            //     different, later technology).
            //   • Composite-only input (1 Vp-p, 75Ω) with switchable Comb/Trap
            //     Y/C separation. Default trap mode means visible dot crawl
            //     and strong chroma fringing on luma edges — the exact
            //     character TI software like Parsec exploited.
            //   • NTSC bandwidth: ~3 MHz luma / ~0.6 MHz chroma → narrow
            //     chroma kernel, moderate luma kernel.
            //   • 23.5 kV anode → moderate brightness, modest bloom.
            //   • 90° deflection era → visible pincushion at corners.
            //   • P22 phosphor → cool whitepoint, slight cross-channel
            //     contamination, slightly impure primaries.
            settings.enabled          = true
            settings.scanlineStrength = 0.45
            settings.maskStrength     = 0.20
            settings.pincushion       = 0.10
            settings.vignette         = 0.18
            settings.beamBlur         = 0.32
            settings.phosphorBleed    = 0.15
            settings.bloomStrength    = 0.45
            settings.colorBleed       = 0.55
            settings.artifacts        = 0.30
            settings.fringing         = 0.15
            settings.hue              = 0
            settings.saturation       = -0.05
            settings.contrast         = 0
            settings.brightness       = 0
            settings.phosphor         = 0.50

        case .heavy:
            settings.enabled          = true
            settings.scanlineStrength = 0.55
            settings.maskStrength     = 0.40
            settings.pincushion       = 0.20
            settings.vignette         = 0.30
            settings.beamBlur         = 0.55
            settings.phosphorBleed    = 0.20
            settings.bloomStrength    = 0.70
            settings.colorBleed       = 0.85
            settings.artifacts        = 0.55
            settings.fringing         = 0.45
            settings.hue              = 0
            settings.saturation       = 0.20
            settings.contrast         = 0.05
            settings.brightness       = 0
            settings.phosphor         = 0.70

        case .defaults:
            // Match the @Published defaults baked into CRTSettings.
            settings.enabled          = true
            settings.scanlineStrength = 0.35
            settings.maskStrength     = 0.25
            settings.pincushion       = 0
            settings.vignette         = 0.15
            settings.beamBlur         = 0.30
            settings.phosphorBleed    = 0.10
            settings.bloomStrength    = 0.50
            settings.colorBleed       = 0.40
            settings.artifacts        = 0.10
            settings.fringing         = 0.10
            settings.hue              = 0
            settings.saturation       = 0
            settings.contrast         = 0
            settings.brightness       = 0
            settings.phosphor         = 0
        }
    }
}

// MARK: - Window controller

/// Manages the standalone CRT controls NSWindow. Resizable so users with
/// smaller screens can shrink/scroll, while large displays get all sliders
/// visible at once.
final class CRTControlsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func showWindow(emulator: Emulator) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = CRTControlsView(settings: emulator.crtSettings)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: 400, height: 720)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CRT Effects"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 380, height: 360)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
