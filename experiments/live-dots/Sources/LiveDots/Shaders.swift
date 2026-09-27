/// Metal source, compiled at launch with `makeLibrary(source:)` so `swift build` needs no
/// Metal toolchain step. Every value the shader bakes in matches `Tuning`.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // cubic-bezier(0.23, 1, 0.32, 1): solve x(t) = p by Newton, return y(t). Same as CubicBezier.swift.
    static float strongEaseOut(float p) {
        p = clamp(p, 0.0f, 1.0f);
        if (p <= 0.0f || p >= 1.0f) { return p; }
        const float x1 = 0.23f, x2 = 0.32f, y1 = 1.0f, y2 = 1.0f;
        float t = p;
        for (int i = 0; i < 8; i++) {
            float u = 1.0f - t;
            float x = 3.0f * u * u * t * x1 + 3.0f * u * t * t * x2 + t * t * t - p;
            float dx = 3.0f * u * u * x1 + 6.0f * u * t * (x2 - x1) + 3.0f * t * t * (1.0f - x2);
            if (fabs(dx) < 1e-6f) { break; }
            t = clamp(t - x / dx, 0.0f, 1.0f);
        }
        float u = 1.0f - t;
        return 3.0f * u * u * t * y1 + 3.0f * u * t * t * y2 + t * t * t;
    }

    // MARK: Camera image

    struct CameraUniforms {
        float2 offset;     // pixels: top-left of the portrait image on screen
        float scale;       // screen pixels per portrait image pixel
        float pad;
        float2 imageSize;  // landscape image size
    };

    struct CameraOut { float4 position [[position]]; };

    vertex CameraOut cameraVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        CameraOut out;
        out.position = float4(p * 2.0f - 1.0f, 0.5f, 1.0f);
        return out;
    }

    // Screen pixel -> portrait pixel -> landscape pixel (turned back 90 degrees counterclockwise).
    fragment float4 cameraFragment(CameraOut in [[stage_in]],
                                   constant CameraUniforms& u [[buffer(0)]],
                                   texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 portrait = (in.position.xy - u.offset) / u.scale;
        float2 landscape = float2(portrait.y, u.imageSize.y - portrait.x);
        return float4(image.sample(s, landscape / u.imageSize).rgb, 1.0f);
    }

    // MARK: Fog comparison veil

    vertex float4 veilVertex(uint vid [[vertex_id]],
                             const device float4* positions [[buffer(0)]],
                             constant float4x4& clip [[buffer(1)]]) {
        return clip * positions[vid];
    }

    fragment float4 veilFragment() {
        return float4(0.0f, 0.0f, 0.0f, 0.35f);
    }

    // MARK: Dots

    struct Sprite {
        float4 a;  // world xyz, 1 for a simulated feature point (fixed size), else 0
        float4 b;  // birth time, from opacity, to opacity, opacity change time
        float4 c;  // edge since, death time, violet (0 or 1), 1 for the halo sprite
        float4 d;  // last observed time (ember), unused x3
    };

    struct DotUniforms {
        float4x4 clip;
        float4 cameraAndTime;  // camera xyz, playback time
        float pointScale;      // pixels per point
        float reduceMotion;    // 1 drops the birth scale
        float scheme;          // 0 hologram, 1 constellation, 2 ember
        float pad;
    };

    constant float3 hologram = float3(0xE6, 0xEC, 0xF4) / 255.0f;
    constant float3 glow = float3(0x9C, 0xC8, 0xFF) / 255.0f;
    constant float3 violet = float3(0xB4, 0x9C, 0xFF) / 255.0f;
    constant float3 emberCore = float3(0xFF, 0xB4, 0x54) / 255.0f;
    constant float3 emberHalo = float3(0xFF, 0xC9, 0x78) / 255.0f;

    // Constellation hides flat dots, so a dot that turns edge is born then, not at its voxel's birth.
    static float visibleBirth(Sprite s, int scheme) {
        return scheme == 1 ? max(s.b.x, s.c.x) : s.b.x;
    }

    struct DotOut {
        float4 position [[position]];
        float size [[point_size]];
        float4 color;
        float inner;  // radius fraction where the soft edge starts
    };

    vertex DotOut dotVertex(uint vid [[vertex_id]],
                            const device Sprite* sprites [[buffer(0)]],
                            constant DotUniforms& u [[buffer(1)]]) {
        Sprite s = sprites[vid];
        float t = u.cameraAndTime.w;
        int scheme = int(u.scheme + 0.5f);
        float birth = strongEaseOut((t - visibleBirth(s, scheme)) / 0.35f);
        float evidence = mix(s.b.y, s.b.z, strongEaseOut((t - s.b.w) / 0.25f));
        // Ember: amber at 90% when observed, cooling linearly to the evidence opacity over 6 s.
        float warmth = scheme == 2 ? clamp(1.0f - (t - s.d.x) / 6.0f, 0.0f, 1.0f) : 0.0f;
        evidence = mix(evidence, 0.9f, warmth);
        float fade = 1.0f - strongEaseOut((t - s.c.y) / 0.25f);
        float edge = strongEaseOut((t - s.c.x) / 0.25f);
        float alpha = evidence * birth * fade;
        bool feature = s.a.w > 0.5f;
        bool halo = s.c.w > 0.5f;

        // Flat 2.5 pt and edge 3.5 pt from 2.5 m out, growing linearly to 4 and 6 pt at 1 m;
        // constellation edges 4.5 pt growing to 7.
        float size = 4.5f;
        if (!feature) {
            float far = clamp((length(s.a.xyz - u.cameraAndTime.xyz) - 1.0f) / 1.5f, 0.0f, 1.0f);
            size = scheme == 1 ? mix(7.0f, 4.5f, far) : mix(mix(4.0f, 2.5f, far), mix(6.0f, 3.5f, far), edge);
        }
        float inner = feature ? 0.3f : 0.7f;
        float3 color = hologram;
        float3 warm = emberCore;
        if (halo) {
            // Edge 4x at 22%, flat 2x at 8%, feature 3x at 18%; a flat dot turning edge grows into it.
            size *= feature ? 3.0f : mix(2.0f, 4.0f, edge);
            alpha *= feature ? 0.18f : mix(0.08f, 0.22f, edge);
            inner = 0.0f;
            color = glow;
            warm = emberHalo;
        }
        color = mix(mix(color, violet, s.c.z), warm, warmth);
        float scale = u.reduceMotion > 0.5f ? 1.0f : mix(0.6f, 1.0f, birth);

        DotOut out;
        out.position = u.clip * float4(s.a.xyz, 1.0f);
        if (alpha < 1.0f / 512.0f) { out.position = float4(0.0f, 0.0f, -1.0f, 1.0f); }
        out.size = size * scale * u.pointScale;
        out.color = float4(color, 1.0f) * alpha;
        out.inner = inner;
        return out;
    }

    // MARK: Constellation links

    struct LinkOut {
        float4 position [[position]];
        float4 color;
    };

    // Each link vertex carries the link's timing (latest birth, earliest death, lower opacity of
    // its two dots), so the line appears and fades with the dots it joins.
    vertex LinkOut linkVertex(uint vid [[vertex_id]],
                              const device Sprite* sprites [[buffer(0)]],
                              constant DotUniforms& u [[buffer(1)]]) {
        Sprite s = sprites[vid];
        float t = u.cameraAndTime.w;
        float birth = strongEaseOut((t - s.b.x) / 0.35f);
        float evidence = mix(s.b.y, s.b.z, strongEaseOut((t - s.b.w) / 0.25f));
        float fade = 1.0f - strongEaseOut((t - s.c.y) / 0.25f);
        LinkOut out;
        out.position = u.clip * float4(s.a.xyz, 1.0f);
        out.color = float4(mix(glow, violet, s.c.z), 1.0f) * (0.35f * evidence * birth * fade);
        return out;
    }

    fragment float4 linkFragment(LinkOut in [[stage_in]]) {
        return in.color;
    }

    // Round sprite, fully opaque inside `inner`, fading to zero at the rim. Halos use 0: a glow.
    fragment float4 dotFragment(DotOut in [[stage_in]], float2 pc [[point_coord]]) {
        float r = length(pc * 2.0f - 1.0f);
        return in.color * (1.0f - smoothstep(in.inner, 1.0f, r));
    }
    """
}
