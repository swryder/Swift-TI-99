// Swift 99/a
//
// CRTView.swift
// Metal-backed display layer used in Monitor Mode only.
//
// Single-pass fragment shader inspired by Blargg's sms_ntsc but rebuilt for
// real-time GPU evaluation rather than a 4096-entry CPU lookup. The pipeline
// per fragment:
//
//   1. Sample 5 horizontal source pixels (nearest, source-pixel grid).
//   2. Convert each to YIQ.
//   3. Blend Y with a sharp Gaussian (luma "beam-spot" — the electron gun
//      profile) and I/Q with a much broader Gaussian (chroma "color bleed" —
//      composite video's ~1.3 MHz chroma bandwidth vs. ~3 MHz luma).
//   4. Phase-modulate artifacts (false color on luma edges) and fringing
//      (brightness shimmer on chroma edges) using a 4-pixel chroma carrier.
//   5. Hue rotate, saturation scale, decode YIQ → RGB.
//   6. Contrast / brightness in RGB space.
//   7. Vertical phosphor bleed (2 linear taps above and below).
//   8. Bloom on near-white highlights only (4 diagonal taps, gated by
//      luminance threshold so mid-tone colors don't halo).
//   9. Scanlines (sin² band per source row), aperture mask, vignette.
//
// Windowed mode does not use this view — it stays on the existing
// CGImage/CALayer path.

import SwiftUI
import AppKit
import MetalKit
import simd

// MARK: - Shader source

private let crtShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle. UV (0,0) = top-left, (1,1) = bottom-right.
vertex VertexOut crt_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    float2 uvs[3]       = { float2( 0,  2), float2( 0, 0), float2(2, 0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

struct CRTUniforms {
    float2 sourceUVOrigin;     // top-left of active picture in source UV
    float2 sourceUVSize;       // size of active picture in source UV
    float2 sourcePixelSize;    // active picture pixels (256, 192)
    float2 outputPixelSize;    // drawable pixels

    // Geometry
    float scanlineStrength;
    float maskStrength;
    float pincushion;
    float vignette;

    // Electron beam
    float beamBlur;
    float phosphorBleed;
    float bloomStrength;

    // Composite NTSC
    float colorBleed;
    float artifacts;
    float fringing;

    // Color grading
    float hue;
    float saturation;
    float contrast;
    float brightness;
    float phosphor;

    float pad0;
};

// NTSC YIQ encode/decode as inline helpers. (Originally these were
// `constant float3x3` globals, but Metal's compiler doesn't always treat
// the matrix constructor as a constant expression — moving the math into
// helpers sidesteps any constexpr ambiguity and lets the compiler inline.)
inline float3 rgb_to_yiq(float3 c) {
    return float3(
        dot(c, float3(0.299,  0.587,  0.114)),
        dot(c, float3(0.596, -0.275, -0.321)),
        dot(c, float3(0.212, -0.523,  0.311))
    );
}

inline float3 yiq_to_rgb(float3 c) {
    return float3(
        c.x + 0.956 * c.y + 0.621 * c.z,
        c.x - 0.272 * c.y - 0.647 * c.z,
        c.x - 1.106 * c.y + 1.703 * c.z
    );
}

fragment float4 crt_fragment(VertexOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant CRTUniforms& u [[buffer(0)]]) {
    constexpr sampler nearest_s(coord::normalized,
                                filter::nearest,
                                address::clamp_to_edge);
    constexpr sampler linear_s(coord::normalized,
                               filter::linear,
                               address::clamp_to_edge);

    // ── 0. Pincushion warp ──
    // 1979 in-line-gun 90° deflection CRTs had visible pincushion: corners
    // pulled inward (opposite of the modern "barrel" curvature shaders).
    // (1 + k·r²) on the centered UV moves output corners to sample from
    // farther-out input positions → input edges bow inward in the picture.
    // Out-of-bounds → black corners (cleaner than smearing edge pixels).
    float2 uv = in.uv;
    {
        float2 cuv = uv - 0.5;
        float r2pin = dot(cuv, cuv);
        uv = 0.5 + cuv * (1.0 + u.pincushion * 0.5 * r2pin);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }
    float2 base = u.sourceUVOrigin + uv * u.sourceUVSize;
    float texelX = u.sourceUVSize.x / u.sourcePixelSize.x;
    float texelY = u.sourceUVSize.y / u.sourcePixelSize.y;

    // ── 1. Sample 5 horizontal taps and convert to YIQ ──
    // Nearest sampling so all output pixels within one source pixel block
    // share the same input — keeps the chroma carrier modulation aligned to
    // the source grid rather than oscillating sub-pixel.
    float3 r0 = src.sample(nearest_s, base + float2(-2.0 * texelX, 0)).rgb;
    float3 r1 = src.sample(nearest_s, base + float2(-1.0 * texelX, 0)).rgb;
    float3 r2 = src.sample(nearest_s, base).rgb;
    float3 r3 = src.sample(nearest_s, base + float2( 1.0 * texelX, 0)).rgb;
    float3 r4 = src.sample(nearest_s, base + float2( 2.0 * texelX, 0)).rgb;

    float3 y0 = rgb_to_yiq(r0);
    float3 y1 = rgb_to_yiq(r1);
    float3 y2 = rgb_to_yiq(r2);
    float3 y3 = rgb_to_yiq(r3);
    float3 y4 = rgb_to_yiq(r4);

    // ── 2. Gaussian-weighted blend, separate kernels for luma and chroma ──
    // beamBlur:    sigma_Y ∈ [1e-3, 1.4] source pixels (sharp → moderate)
    // colorBleed:  sigma_C ∈ [0.5, 3.0]  source pixels (always at least
    //              mildly soft — composite chroma is never perfectly sharp)
    float sigmaY = max(u.beamBlur * 1.4, 1e-3);
    float sigmaC = mix(0.5, 3.0, u.colorBleed);

    float invSig2Y = 1.0 / (2.0 * sigmaY * sigmaY);
    float invSig2C = 1.0 / (2.0 * sigmaC * sigmaC);

    float kY1 = exp(-1.0 * invSig2Y);
    float kY2 = exp(-4.0 * invSig2Y);
    float sumY = 1.0 + 2.0 * kY1 + 2.0 * kY2;
    kY1 /= sumY;
    kY2 /= sumY;
    float kY0 = 1.0 / sumY;

    float kC1 = exp(-1.0 * invSig2C);
    float kC2 = exp(-4.0 * invSig2C);
    float sumC = 1.0 + 2.0 * kC1 + 2.0 * kC2;
    kC1 /= sumC;
    kC2 /= sumC;
    float kC0 = 1.0 / sumC;

    float Y = y2.x * kY0 + (y1.x + y3.x) * kY1 + (y0.x + y4.x) * kY2;
    float I = y2.y * kC0 + (y1.y + y3.y) * kC1 + (y0.y + y4.y) * kC2;
    float Q = y2.z * kC0 + (y1.z + y3.z) * kC1 + (y0.z + y4.z) * kC2;

    // ── 3. Phase-modulated artifacts and fringing ──
    // 4-pixel chroma carrier period. Snap phase to source-pixel grid so the
    // rainbow stays cell-locked instead of shimmering sub-pixel under the
    // scanline pattern.
    float xCell = floor(uv.x * u.sourcePixelSize.x);
    float phase = xCell * 1.5707963;          // π/2 per pixel
    float sinP = sin(phase);
    float cosP = cos(phase);

    // High-frequency luma is the difference between the sharp center pixel
    // and the blurred Y — strong on dark/bright edges, zero in flat regions.
    float lumaHF = y2.x - Y;
    // High-frequency chroma magnitude: how much the center I/Q differs from
    // the blurred I/Q.
    float chromaHF = length(float2(y2.y - I, y2.z - Q));

    I += u.artifacts * lumaHF * sinP * 0.6;
    Q += u.artifacts * lumaHF * cosP * 0.6;
    Y += u.fringing  * chromaHF * sinP * 0.3;

    // ── 4. Hue + saturation in YIQ space ──
    float hueAngle = u.hue * 3.14159265;
    float ch = cos(hueAngle);
    float sh = sin(hueAngle);
    float Inew = I * ch - Q * sh;
    float Qnew = I * sh + Q * ch;
    I = Inew;
    Q = Qnew;
    float satScale = max(1.0 + u.saturation, 0.0);
    I *= satScale;
    Q *= satScale;

    // ── 5. Decode YIQ → RGB ──
    float3 color = yiq_to_rgb(float3(Y, I, Q));

    // ── 6. Contrast + brightness ──
    float contrastScale = max(1.0 + u.contrast, 0.0);
    color = (color - 0.5) * contrastScale + 0.5;
    color += u.brightness;

    // ── 7. Vertical phosphor bleed ──
    // Two linear taps one source pixel above and below. Only mixed in by half
    // the slider value so even at maximum the center pixel keeps its identity.
    float3 vT = src.sample(linear_s, base + float2(0, -texelY)).rgb;
    float3 vB = src.sample(linear_s, base + float2(0,  texelY)).rgb;
    float3 vBlend = (vT + vB) * 0.5;
    color = mix(color, vBlend, u.phosphorBleed * 0.5);

    // ── 8. Bloom (gated, near-white only) ──
    // Sub-pixel diagonal offsets — any glow contribution merges with the
    // pixel rather than appearing as an offset rim. Smooth threshold ramp
    // around 0.80 luma so TI cyan (~0.78) does not bloom but real whites do.
    float2 diag = float2(texelX, texelY) * 0.75;
    float3 d1 = src.sample(linear_s, base + diag).rgb;
    float3 d2 = src.sample(linear_s, base + diag * float2(-1, 1)).rgb;
    float3 d3 = src.sample(linear_s, base + diag * float2( 1,-1)).rgb;
    float3 d4 = src.sample(linear_s, base + diag * float2(-1,-1)).rgb;
    float3 soft = (d1 + d2 + d3 + d4) * 0.25;
    float softLum = dot(soft, float3(0.299, 0.587, 0.114));
    float bloomGate = saturate((softLum - 0.80) / 0.20);
    bloomGate = bloomGate * bloomGate;
    float3 bloom = soft * bloomGate * u.bloomStrength;

    // ── 9. Scanlines: sin² band per source row ──
    float scanY = uv.y * u.sourcePixelSize.y;
    float band = sin(fract(scanY) * 3.14159265);
    band = band * band;
    float scanlineMod = mix(1.0, band, u.scanlineStrength);

    // ── 10. P22 phosphor color matrix ──
    // 1979-era P22 phosphors weren't pure sRGB primaries — they had
    // cross-channel contamination (slight green tint on blue, slightly
    // impure red, etc.) and a cool whitepoint. Blend toward a P22-flavored
    // matrix proportional to the phosphor slider.
    float pp = u.phosphor;
    float3 pColor = float3(
        (1.0 - 0.05*pp) * color.r + (0.05*pp) * color.g,
        (0.04*pp) * color.r + (1.0 - 0.07*pp) * color.g + (0.03*pp) * color.b,
        (0.05*pp) * color.g + (1.0 - 0.03*pp) * color.b
    );
    color = pColor;

    // ── 11. Slot mask: vertical RGB triads, alternate rows offset by half a
    // triad (brick pattern), with a subtle horizontal gap between rows. This
    // is what 1979 in-line-gun consumer monitors actually used (shadow mask
    // family). Aperture grille / Trinitron is a different, later thing.
    float xPxOut = uv.x * u.outputPixelSize.x;
    float yPxOut = uv.y * u.outputPixelSize.y;
    float slotHeight = 6.0;                              // output pixels per slot row
    float slotRow = floor(yPxOut / slotHeight);
    float rowOffset = fmod(slotRow, 2.0) * 1.5;          // 1.5 stripes = half a triad
    float maskPhase = fract((xPxOut + rowOffset) / 3.0);
    float3 stripe;
    if (maskPhase < 1.0/3.0)      stripe = float3(1.10, 0.65, 0.65);
    else if (maskPhase < 2.0/3.0) stripe = float3(0.65, 1.10, 0.65);
    else                          stripe = float3(0.65, 0.65, 1.10);
    // Thin dark gap between slot rows — sells the "discrete slots"
    // character versus continuous stripes.
    float yIntraSlot = fract(yPxOut / slotHeight);
    float gapDarken = smoothstep(0.85, 1.0, yIntraSlot);
    stripe *= 1.0 - gapDarken * 0.45;
    float3 maskMod = mix(float3(1.0), stripe, u.maskStrength);

    // ── 12. Vignette ──
    float2 vc = uv - 0.5;
    float rSquared = dot(vc, vc) * 4.0;
    float vignetteMod = 1.0 - rSquared * u.vignette;

    color = color * scanlineMod * maskMod + bloom;
    color *= vignetteMod;

    return float4(max(color, 0.0), 1.0);
}
"""

// MARK: - Uniform layout (must match CRTUniforms in MSL)

private struct CRTUniforms {
    var sourceUVOrigin: SIMD2<Float>
    var sourceUVSize: SIMD2<Float>
    var sourcePixelSize: SIMD2<Float>
    var outputPixelSize: SIMD2<Float>

    var scanlineStrength: Float
    var maskStrength: Float
    var pincushion: Float
    var vignette: Float

    var beamBlur: Float
    var phosphorBleed: Float
    var bloomStrength: Float

    var colorBleed: Float
    var artifacts: Float
    var fringing: Float

    var hue: Float
    var saturation: Float
    var contrast: Float
    var brightness: Float
    var phosphor: Float

    var pad0: Float = 0
}

// MARK: - Renderer

final class CRTRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sourceTexture: MTLTexture
    private var drawableSize: CGSize = .zero

    let settings: CRTSettings

    init?(device: MTLDevice,
          pixelFormat: MTLPixelFormat,
          settings: CRTSettings) {
        self.device = device
        self.settings = settings

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: crtShaderSource, options: nil)
        } catch {
            print("CRT: failed to compile Metal shader: \(error)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "crt_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "crt_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("CRT: failed to create render pipeline: \(error)")
            return nil
        }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: TMS_WIDTH,
            height: TMS_HEIGHT,
            mipmapped: false)
        texDesc.usage = .shaderRead
        texDesc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: texDesc) else { return nil }
        self.sourceTexture = tex

        super.init()
    }

    /// Copy a CGImage produced by TMS9918.pushFrame() into the GPU texture.
    /// CGImage bytes are little-endian ARGB (= BGRA in memory) → matches
    /// `.bgra8Unorm` directly with no conversion.
    func updateFrame(_ image: CGImage) {
        guard image.width == TMS_WIDTH, image.height == TMS_HEIGHT,
              let provider = image.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data)
        else { return }
        let region = MTLRegionMake2D(0, 0, TMS_WIDTH, TMS_HEIGHT)
        sourceTexture.replace(region: region,
                              mipmapLevel: 0,
                              withBytes: bytes,
                              bytesPerRow: image.bytesPerRow)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let originX = Float(TMS_FIRST_DISPLAY_PIXEL) / Float(TMS_WIDTH)
        let originY = Float(TMS_FIRST_DISPLAY_LINE)  / Float(TMS_HEIGHT)
        let sizeX   = Float(TMS_DISPLAY_WIDTH)       / Float(TMS_WIDTH)
        let sizeY   = Float(TMS_DISPLAY_HEIGHT)      / Float(TMS_HEIGHT)

        let outW = Float(drawableSize.width  > 0 ? drawableSize.width  : view.bounds.width)
        let outH = Float(drawableSize.height > 0 ? drawableSize.height : view.bounds.height)

        let on = settings.enabled
        let s = settings
        var u = CRTUniforms(
            sourceUVOrigin:   SIMD2(originX, originY),
            sourceUVSize:     SIMD2(sizeX, sizeY),
            sourcePixelSize:  SIMD2(Float(TMS_DISPLAY_WIDTH), Float(TMS_DISPLAY_HEIGHT)),
            outputPixelSize:  SIMD2(outW, outH),
            scanlineStrength: on ? s.scanlineStrength : 0,
            maskStrength:     on ? s.maskStrength     : 0,
            pincushion:       on ? s.pincushion       : 0,
            vignette:         on ? s.vignette         : 0,
            beamBlur:         on ? s.beamBlur         : 0,
            phosphorBleed:    on ? s.phosphorBleed    : 0,
            bloomStrength:    on ? s.bloomStrength    : 0,
            colorBleed:       on ? s.colorBleed       : 0,
            artifacts:        on ? s.artifacts        : 0,
            fringing:         on ? s.fringing         : 0,
            hue:              on ? s.hue              : 0,
            saturation:       on ? s.saturation       : 0,
            contrast:         on ? s.contrast         : 0,
            brightness:       on ? s.brightness       : 0,
            phosphor:         on ? s.phosphor         : 0)

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(sourceTexture, index: 0)
        enc.setFragmentBytes(&u,
                             length: MemoryLayout<CRTUniforms>.stride,
                             index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

// MARK: - SwiftUI wrapper

struct CRTView: NSViewRepresentable {
    let image: CGImage?
    let cornerRadius: CGFloat
    @ObservedObject var settings: CRTSettings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return MTKView(frame: .zero)
        }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoResizeDrawable = true

        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.backgroundColor = NSColor.black.cgColor

        if let renderer = CRTRenderer(device: device,
                                      pixelFormat: view.colorPixelFormat,
                                      settings: settings) {
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        guard let renderer = context.coordinator.renderer else { return }
        if let image = image {
            renderer.updateFrame(image)
        }
        view.setNeedsDisplay(view.bounds)
    }

    final class Coordinator {
        var renderer: CRTRenderer?
    }
}
