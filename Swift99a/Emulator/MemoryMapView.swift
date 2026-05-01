// Swift 99/a
//
// MemoryMapView.swift
// Real-time visualization of the TI-99/4A's 64KB CPU address space as a 256×256
// pixel image (one pixel per byte). Each byte's value is mapped to a color via
// a selectable palette (rainbow HSV or green phosphor monochrome).
//
// Rendering is GPU-accelerated using Metal. Three .storageModeShared MTLBuffers
// hold the memory bytes, read heat, and write heat. A fragment shader does the
// per-pixel palette lookup and HDR heat blending each frame, eliminating the
// per-frame CGImage allocation and Swift per-pixel loop of the old CPU path.
//
// An optional heat overlay highlights memory access activity:
//   - Blue tint for reads, red tint for writes, purple for both
//   - Recent accesses flash bright white using HDR extended-range rendering
//     (up to ~2000 nits on supported displays) and decay through the
//     access-type color back to the base palette color
//
// Two update modes are supported:
//   - Timer mode: pushes new data at a fixed 15 fps from the main run loop
//   - CPU-sync mode: triggered by emulator CPU ticks (~1000 Hz), throttled
//     to display refresh rate (~60 fps)
//
// The visualization opens in a fixed-size, non-resizable window. The map is
// rendered at 512×512 points (1024×1024 device pixels on retina) for a clean
// 4× integer scale of the underlying 256×256 byte grid.

import Foundation
import SwiftUI
import Combine
import MetalKit
import CoreGraphics
import simd

// MARK: - Palettes

/// Palette mode for memory map byte visualization
enum MemoryMapPalette: Int {
    case rainbow     // HSV hue sweep — colorful, shows byte value as color
    case monochrome  // Green intensity — byte value as brightness
}

/// Pre-computed rainbow palette: 0 = black, 1-255 = HSV hue sweep
private let rainbowPalette: [UInt32] = {
    var palette = [UInt32](repeating: 0, count: 256)
    palette[0] = 0xFF000000  // Black for zero bytes
    for i in 1...255 {
        let hue = Double(i - 1) / 254.0
        let h = hue * 6.0
        let sector = Int(h)
        let f = h - Double(sector)
        let q = 1.0 - f
        let t = f
        var r: Double, g: Double, b: Double
        switch sector % 6 {
        case 0: r = 1; g = t; b = 0
        case 1: r = q; g = 1; b = 0
        case 2: r = 0; g = 1; b = t
        case 3: r = 0; g = q; b = 1
        case 4: r = t; g = 0; b = 1
        default: r = 1; g = 0; b = q
        }
        let ri = UInt32(r * 255)
        let gi = UInt32(g * 255)
        let bi = UInt32(b * 255)
        palette[i] = 0xFF000000 | (ri << 16) | (gi << 8) | bi
    }
    return palette
}()

/// Pre-computed monochrome green palette: byte value → green intensity
/// Uses a pleasant phosphor green (R:0.18, G:1.0, B:0.30) scaled by intensity
private let monoGreenPalette: [UInt32] = {
    var palette = [UInt32](repeating: 0, count: 256)
    palette[0] = 0xFF000000  // Black for zero bytes
    for i in 1...255 {
        let t = Double(i) / 255.0
        let ri = UInt32(t * 0.18 * 255)
        let gi = UInt32(t * 1.00 * 255)
        let bi = UInt32(t * 0.30 * 255)
        palette[i] = 0xFF000000 | (ri << 16) | (gi << 8) | bi
    }
    return palette
}()

private func paletteFloats(for mode: MemoryMapPalette) -> [SIMD4<Float>] {
    let source = mode == .rainbow ? rainbowPalette : monoGreenPalette
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(256)
    for v in source {
        let r = Float((v >> 16) & 0xFF) / 255.0
        let g = Float((v >> 8) & 0xFF) / 255.0
        let b = Float(v & 0xFF) / 255.0
        out.append(SIMD4<Float>(r, g, b, 1.0))
    }
    return out
}

// MARK: - Update Mode

/// Update mode for the memory map visualization
enum MemoryMapUpdateMode: Int {
    case timer      // Fixed 15 fps timer
    case cpuSync    // Synced to emulator CPU ticks (~1000 Hz, throttled to display)
}

// MARK: - Metal Renderer

private struct MemoryMapUniforms {
    var heatEnabled: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// Metal Shading Language source compiled at runtime. Avoids needing a separate
/// .metal file added to the Xcode target.
private let memoryMapShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle. UV is (0,0) at top-left, (1,1) at bottom-right.
vertex VertexOut memmap_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    float2 uvs[3]       = { float2( 0,  2), float2( 0, 0), float2(2, 0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

struct Uniforms {
    uint heatEnabled;
};

constant float HDR_PEAK = 8.0;

fragment float4 memmap_fragment(VertexOut in [[stage_in]],
                                device const uchar* memory     [[buffer(0)]],
                                device const uchar* readHeat   [[buffer(1)]],
                                device const uchar* writeHeat  [[buffer(2)]],
                                device const float4* palette   [[buffer(3)]],
                                constant Uniforms& uniforms    [[buffer(4)]]) {
    // Map UV → byte index. Address 0x0000 is top-left, 0xFFFF is bottom-right.
    uint x = uint(clamp(in.uv.x, 0.0, 0.999999) * 256.0);
    uint y = uint(clamp(in.uv.y, 0.0, 0.999999) * 256.0);
    uint i = y * 256u + x;

    uchar byte = memory[i];
    float4 base = palette[byte];

    if (uniforms.heatEnabled == 0u) {
        return base;
    }

    uchar rv = readHeat[i];
    uchar wv = writeHeat[i];

    if (rv == 0 && wv == 0) {
        return base;
    }

    float ri = float(rv) / 255.0;
    float wi = float(wv) / 255.0;
    float heat = max(ri, wi);
    float total = ri + wi;

    // Access-type tint colors:
    //   pure read  = (0.3, 0.5, 1.0) — blue
    //   pure write = (1.0, 0.3, 0.2) — red
    //   both       = blend between them
    float3 tint = float3((wi * 1.0 + ri * 0.3) / total,
                         (wi * 0.3 + ri * 0.5) / total,
                         (wi * 0.2 + ri * 1.0) / total);

    // Two-stage blend:
    //   heat 0.0..0.5 → base color fades to access-type tint
    //   heat 0.5..1.0 → tint brightens to HDR white peak
    float3 outColor;
    if (heat <= 0.5) {
        float t = heat * 2.0;
        outColor = mix(base.rgb, tint, t);
    } else {
        float t = (heat - 0.5) * 2.0;
        outColor = mix(tint, float3(HDR_PEAK), t);
    }

    return float4(outColor, 1.0);
}
"""

/// Holds the Metal pipeline state, palette buffer, and three shared-storage
/// buffers (memory + read heat + write heat). Acts as the MTKViewDelegate that
/// renders one frame per setNeedsDisplay tick.
final class MemoryMapMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    /// 64KB byte buffer mirroring the CPU address space.
    private let memoryBuffer: MTLBuffer
    /// 64KB byte buffer of read-heat values (0..255).
    private let readHeatBuffer: MTLBuffer
    /// 64KB byte buffer of write-heat values (0..255).
    private let writeHeatBuffer: MTLBuffer
    /// 256 × float4 palette LUT.
    private let paletteBuffer: MTLBuffer

    var heatEnabled: Bool = true
    var paletteMode: MemoryMapPalette = .rainbow {
        didSet { updatePaletteBuffer() }
    }

    /// Direct CPU-writable pointer to the GPU's shared memory buffer (64KB).
    /// Used by the model to copy emulator state directly without an intermediate
    /// Swift array allocation.
    var memoryContents: UnsafeMutableRawPointer { memoryBuffer.contents() }
    var readHeatContents: UnsafeMutableRawPointer { readHeatBuffer.contents() }
    var writeHeatContents: UnsafeMutableRawPointer { writeHeatBuffer.contents() }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let mem = device.makeBuffer(length: 65536, options: .storageModeShared),
              let rh  = device.makeBuffer(length: 65536, options: .storageModeShared),
              let wh  = device.makeBuffer(length: 65536, options: .storageModeShared),
              let pal = device.makeBuffer(length: 256 * MemoryLayout<SIMD4<Float>>.stride,
                                          options: .storageModeShared)
        else { return nil }
        self.memoryBuffer = mem
        self.readHeatBuffer = rh
        self.writeHeatBuffer = wh
        self.paletteBuffer = pal

        memset(mem.contents(), 0, 65536)
        memset(rh.contents(), 0, 65536)
        memset(wh.contents(), 0, 65536)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: memoryMapShaderSource, options: nil)
        } catch {
            print("MemoryMap: failed to compile Metal shader: \(error)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "memmap_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "memmap_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("MemoryMap: failed to create render pipeline: \(error)")
            return nil
        }

        super.init()
        updatePaletteBuffer()
    }

    private func updatePaletteBuffer() {
        let entries = paletteFloats(for: paletteMode)
        let dst = paletteBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 256)
        for i in 0..<256 {
            dst[i] = entries[i]
        }
    }

    /// Zero out the heat buffers — used when heat overlay is disabled, so the
    /// shader doesn't render stale heat values from a previous toggled-on session.
    func clearHeatBuffers() {
        memset(readHeatBuffer.contents(), 0, 65536)
        memset(writeHeatBuffer.contents(), 0, 65536)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var uniforms = MemoryMapUniforms(heatEnabled: heatEnabled ? 1 : 0)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(memoryBuffer,    offset: 0, index: 0)
        encoder.setFragmentBuffer(readHeatBuffer,  offset: 0, index: 1)
        encoder.setFragmentBuffer(writeHeatBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(paletteBuffer,   offset: 0, index: 3)
        encoder.setFragmentBytes(&uniforms,
                                  length: MemoryLayout<MemoryMapUniforms>.stride,
                                  index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Model

/// Drives memory snapshots and pushes them to the Metal renderer.
final class MemoryMapModel: ObservableObject {
    @Published var heatOverlayEnabled: Bool = true
    @Published var paletteMode: MemoryMapPalette = .rainbow
    @Published var updateMode: MemoryMapUpdateMode = .timer {
        didSet {
            guard oldValue != updateMode else { return }
            restartUpdating()
        }
    }

    /// Renderer the model writes snapshots into directly. Set by
    /// MemoryMapMetalView once its MTKView is created.
    weak var renderer: MemoryMapMetalRenderer?

    /// Closure invoked on the main thread after a snapshot has been written
    /// into the renderer's shared buffers. Should request a redraw.
    var triggerRedraw: (() -> Void)?

    private weak var emulator: Emulator?
    private var timer: Timer?

    /// Throttle for CPU-sync mode: minimum interval between renders
    private let cpuSyncMinInterval: TimeInterval = 1.0 / 60.0
    private var lastCpuSyncRender: CFAbsoluteTime = 0

    init(emulator: Emulator) {
        self.emulator = emulator
    }

    func startUpdating() {
        guard let emulator = emulator else { return }

        emulator.emulatorQueue.sync {
            let tracker = MemoryAccessTracker(size: emulator.system.memorySize)
            emulator.system.accessTracker = tracker
        }

        switch updateMode {
        case .timer:   startTimerMode()
        case .cpuSync: startCpuSyncMode()
        }

        pushSnapshot()
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil

        if let emulator = emulator {
            emulator.emulatorQueue.sync {
                emulator.system.memoryMapCallback = nil
                emulator.system.accessTracker = nil
            }
        }
    }

    private func restartUpdating() {
        guard emulator != nil else { return }
        timer?.invalidate()
        timer = nil
        if let emulator = emulator {
            emulator.emulatorQueue.sync {
                emulator.system.memoryMapCallback = nil
            }
        }
        switch updateMode {
        case .timer:   startTimerMode()
        case .cpuSync: startCpuSyncMode()
        }
    }

    private func startTimerMode() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.pushSnapshot()
        }
    }

    private func startCpuSyncMode() {
        guard let emulator = emulator else { return }
        emulator.emulatorQueue.sync {
            emulator.system.memoryMapCallback = { [weak self] in
                self?.cpuSyncTick()
            }
        }
    }

    /// Called on emulatorQueue at ~1000 Hz. Throttles snapshots to display rate.
    private func cpuSyncTick() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCpuSyncRender >= cpuSyncMinInterval else { return }
        lastCpuSyncRender = now
        captureAndRedraw()
    }

    private func pushSnapshot() {
        guard let emulator = emulator else { return }
        emulator.emulatorQueue.sync {
            captureAndRedraw()
        }
    }

    /// Snapshot directly into the renderer's shared GPU buffers, then request a
    /// redraw on the main thread. Must be called on the emulator queue.
    private func captureAndRedraw() {
        guard let emulator = emulator, let renderer = renderer else { return }
        let system = emulator.system

        // Memory: ~10 µs memcpy from the shadow buffer (vs. ~13 ms peek-loop).
        system.snapshotMemoryInto(renderer.memoryContents)

        if heatOverlayEnabled, let tracker = system.accessTracker {
            // Heat: ~50 µs combined copy + decay, no allocations.
            tracker.snapshotAndDecayInto(reads: renderer.readHeatContents,
                                          writes: renderer.writeHeatContents)
        }
        // When heat is disabled the shader ignores the heat buffers via the
        // heatEnabled uniform, so we leave them untouched (saves ~25 µs/frame
        // and lets the buffers retain whatever was last drawn).

        DispatchQueue.main.async { [weak self] in
            self?.triggerRedraw?()
        }
    }
}

// MARK: - SwiftUI Metal View

/// Hosts an MTKView inside SwiftUI, owns the renderer, and bridges the model's
/// renderHandler callback to GPU buffer uploads + redraws.
struct MemoryMapMetalView: NSViewRepresentable {
    @ObservedObject var model: MemoryMapModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Fall back to a black view if Metal is unavailable. Should never
            // happen on macOS 11+, but avoid a hard crash.
            return MTKView(frame: .zero)
        }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoResizeDrawable = true

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.magnificationFilter = .nearest
            metalLayer.minificationFilter = .nearest
        }

        if let renderer = MemoryMapMetalRenderer(device: device,
                                                  pixelFormat: view.colorPixelFormat) {
            renderer.heatEnabled = model.heatOverlayEnabled
            renderer.paletteMode = model.paletteMode
            view.delegate = renderer
            context.coordinator.renderer = renderer
            context.coordinator.view = view

            // The model writes snapshots directly into the renderer's shared
            // MTLBuffers (no Swift array round-trip); we just request a redraw.
            model.renderer = renderer
            model.triggerRedraw = { [weak view] in
                view?.setNeedsDisplay(view?.bounds ?? .zero)
            }
        }

        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        let heatChangedToOff = renderer.heatEnabled && !model.heatOverlayEnabled
        renderer.heatEnabled = model.heatOverlayEnabled
        renderer.paletteMode = model.paletteMode
        if heatChangedToOff {
            // Wipe stale heat so a future re-enable doesn't flash old values.
            renderer.clearHeatBuffers()
        }
        view.setNeedsDisplay(view.bounds)
    }

    final class Coordinator {
        var renderer: MemoryMapMetalRenderer?
        weak var view: MTKView?
    }
}

// MARK: - SwiftUI View

/// The memory map window content
struct MemoryMapView: View {
    @StateObject private var model: MemoryMapModel

    init(emulator: Emulator) {
        _model = StateObject(wrappedValue: MemoryMapModel(emulator: emulator))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Memory map: GPU-rendered Metal view at fixed 512×512 points.
            // Backing drawable scales with the display: 1024×1024 px on retina.
            ZStack {
                Color.black
                MemoryMapMetalView(model: model)
            }
            .frame(width: 512, height: 512)

            // Controls area with standard window background
            VStack(spacing: 6) {
                // Address labels
                HStack {
                    Text("0x0000")
                    Spacer()
                    Text("0x8000")
                    Spacer()
                    Text("0xFFFF")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

                // Region legend
                HStack(spacing: 12) {
                    legendItem("ROM", range: "0000-1FFF")
                    legendItem("Exp", range: "2000-3FFF")
                    legendItem("Cart", range: "4000-7FFF")
                    legendItem("I/O", range: "8000-9FFF")
                    legendItem("RAM", range: "A000-FFFF")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)

                Divider()

                // Access heat overlay controls
                HStack(spacing: 12) {
                    Toggle("Access Heat", isOn: $model.heatOverlayEnabled)
                        .toggleStyle(.checkbox)

                    if model.heatOverlayEnabled {
                        HStack(spacing: 8) {
                            Circle().fill(Color.blue).frame(width: 8, height: 8)
                            Text("Read")
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("Write")
                            Circle().fill(Color.purple).frame(width: 8, height: 8)
                            Text("R+W")
                        }
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    Picker("Palette", selection: $model.paletteMode) {
                        Text("Rainbow").tag(MemoryMapPalette.rainbow)
                        Text("Green").tag(MemoryMapPalette.monochrome)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Picker("Update", selection: $model.updateMode) {
                        Text("15 fps").tag(MemoryMapUpdateMode.timer)
                        Text("CPU Sync").tag(MemoryMapUpdateMode.cpuSync)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .onAppear { model.startUpdating() }
        .onDisappear { model.stopUpdating() }
    }

    private func legendItem(_ name: String, range: String) -> some View {
        Text("\(name) \(range)")
    }
}

// MARK: - Memory Map Window

/// Environment key for tracking whether the memory map window is visible
struct MemoryMapWindowKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

/// Manages the standalone memory map NSWindow at a fixed, non-resizable size.
final class MemoryMapWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Fixed size for the map area in points. 512 → 4× integer scale of the
    /// 256-byte source on retina, 2× on non-retina.
    private let mapSize: CGFloat = 512

    /// Fixed height of the controls area below the square map
    private let controlsHeight: CGFloat = 100

    func showWindow(emulator: Emulator) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = MemoryMapView(emulator: emulator)
        let hostingView = NSHostingView(rootView: view)

        let contentSize = NSSize(width: mapSize, height: mapSize + controlsHeight)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Memory Map — 64KB Address Space"
        window.contentView = hostingView
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}
