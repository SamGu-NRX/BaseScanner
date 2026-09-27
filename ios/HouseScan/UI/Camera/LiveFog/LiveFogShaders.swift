/// Metal source for the live fog and dots, compiled at runtime (`makeLibrary(source:)`) so the
/// build needs no Metal toolchain, as in the prototype (experiments/live-dots on t3/experience,
/// `Shaders.swift`). Struct layouts match the Swift structs in `LiveFogRenderer.swift`.
///
/// Fog. Coverage decides where it lifts: `LiveFogScene` draws every wall column and ground
/// stretch of the coverage strip into a mask three times 64 texels wide (red: fog, green: hidden
/// behind something, blue: requested by a gap, alpha: still changing), clearing to full fog; a
/// max-pool takes it to 64 texels and a radius-3 Gaussian blur feathers it. The composite is the
/// prototype's: Chalk mixed toward a cool grey, textured by slow domain-warped fbm and breathing
/// slightly. Two changes: the noise is pinned to the meter
/// on screen and scaled by its distance, so the texture sits on the wall instead of on the lens
/// while the phone moves (the prototype cut between keyframes, where that never showed); and
/// part-lifted fog breaks up along the same noise instead of thinning evenly, so a lift reads as
/// mist burning off.
///
/// Dots. The prototype's hologram scheme: additive point sprites, a halo under each core, births
/// that ease in over 350 ms from 60% size, opacity changes over 250 ms, deaths over 250 ms. A dot
/// under fog draws at 20%, so dots arrive where coverage lifts the fog; dots on an occluder
/// (violet) draw fully, since they are what the hidden state is about.
enum LiveFogShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // cubic-bezier(0.23, 1, 0.32, 1), solved by Newton.
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

    struct FullOut { float4 position [[position]]; };

    vertex FullOut fullVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        FullOut out;
        out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
        return out;
    }

    // MARK: Mask

    struct MaskVertex {
        float4 position;  // world xyz
        float4 value;     // fog, hidden, requested, 1 while the cell's fog is changing
    };

    struct MaskOut {
        float4 position [[position]];
        float4 value [[flat]];
    };

    vertex MaskOut maskVertex(uint vid [[vertex_id]],
                              const device MaskVertex* vertices [[buffer(0)]],
                              constant float4x4& clip [[buffer(1)]]) {
        MaskOut out;
        out.position = clip * float4(vertices[vid].position.xyz, 1.0f);
        out.value = vertices[vid].value;
        return out;
    }

    fragment float4 maskFragment(MaskOut in [[stage_in]]) {
        return in.value;
    }

    // Each texel takes the largest value of the 3 x 3 block under it in the mask drawn at three
    // times the size, per channel: a cell as narrow as one fine texel (about 2 points) still
    // reaches the coarse mask, where sampling alone could step over it.
    fragment float4 poolFragment(FullOut in [[stage_in]],
                                 texture2d<float> fine [[texture(0)]]) {
        uint2 base = uint2(in.position.xy) * 3u;
        uint2 limit = uint2(fine.get_width() - 1, fine.get_height() - 1);
        float4 m = float4(0.0f);
        for (uint y = 0; y < 3; y++) {
            for (uint x = 0; x < 3; x++) {
                m = max(m, fine.read(min(base + uint2(x, y), limit)));
            }
        }
        return m;
    }

    // Separable Gaussian, radius 3 texels (sigma 1.4, about 8 points), all four channels.
    fragment float4 blurFragment(FullOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 constant int2& direction [[buffer(0)]]) {
        int2 p = int2(in.position.xy);
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float4 sum = float4(0.0f);
        float total = 0.0f;
        for (int k = -3; k <= 3; k++) {
            float w = exp(-float(k * k) / (2.0f * 1.4f * 1.4f));
            sum += w * source.read(uint2(clamp(p + k * direction, int2(0), limit)));
            total += w;
        }
        return sum / total;
    }

    // MARK: Fog

    struct FogUniforms {
        float2 viewSize;    // drawable pixels
        float2 anchor;      // pixels: the meter on screen, where the noise is pinned
        float anchorScale;  // pixels per noise unit (about 1.2 m at the meter)
        float time;         // seconds
        float motion;       // 0 under Reduce Motion: no drift, no breathing, no pulse
        float pad;
        float4 requested;   // the gap request's amber, rgb
    };

    static float hash21(float2 p) {
        p = fract(p * float2(123.34f, 456.21f));
        p += dot(p, p + 45.32f);
        return fract(p.x * p.y);
    }

    static float valueNoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0f - 2.0f * f);
        float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
    }

    static float fbm(float2 p) {
        float sum = 0.0f, amplitude = 0.5f;
        for (int i = 0; i < 3; i++) {
            sum += amplitude * valueNoise(p);
            p = p * 2.03f + float2(17.1f, 9.2f);
            amplitude *= 0.5f;
        }
        return sum / 0.875f;
    }

    fragment float4 fogFragment(FullOut in [[stage_in]],
                                constant FogUniforms& u [[buffer(0)]],
                                texture2d<float> mask [[texture(0)]],
                                texture2d<float> pooled [[texture(1)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float2 screen = in.position.xy;
        // Wrapped so the offsets stay small where Float precision is fine.
        float2 uv = fmod((screen - u.anchor) / u.anchorScale, float2(256.0f));
        float2 q = uv + u.motion * u.time * 0.02f * float2(0.94f, 0.34f);

        // The mask is read through a fine noise offset, about 27 cm features at the meter and at
        // most 2.5% of the screen's width either way, so the straight edges of cells come out
        // ragged, as a fog bank's do (the noise-edged fog of war the prototype borrowed from
        // Civilization VI). A coarser, larger offset (70 cm, 7%) smeared the edges into what
        // read as a smudge on the lens in the first hosted screenshots.
        float2 edgeNoise = float2(valueNoise(q * 4.5f + float2(7.3f, 2.1f)), valueNoise(q * 4.5f + float2(-4.1f, 8.6f)));
        float2 look = screen + (edgeNoise - 0.5f) * 0.05f * u.viewSize.x;
        // The blur and the noise shape the fog; neither may erase it. The unblurred pooled mask,
        // read through a smaller offset, sets a floor: a cell coverage has not counted keeps 30%
        // of its fog within a few points of where it is, however narrow. Read unwarped, the floor
        // drew a straight step along every wide edge.
        float2 near = screen + (edgeNoise - 0.5f) * 0.015f * u.viewSize.x;
        float4 m = max(mask.sample(linear, look / u.viewSize), 0.3f * pooled.sample(linear, near / u.viewSize));
        float fog = saturate(m.r), hidden = saturate(m.g), requested = saturate(m.b);
        if (fog < 0.002f && requested < 0.002f) { return float4(0.0f); }

        float2 warp = float2(fbm(q + float2(3.1f, 1.7f)), fbm(q + float2(-2.3f, 5.2f)));
        float n = fbm(q + 0.8f * warp);
        // The prototype's texture is barely there; deeper troughs read as dirt on the lens.
        float noiseTerm = 0.88f + 0.12f * n;
        float breathing = 1.0f + u.motion * 0.04f * sin(2.0f * M_PI_F * 0.08f * u.time);

        // Lifting fog breaks up along the noise, as mist burning off; fog that holds still (a cell
        // seen once) stays an even, thinner veil, since held blotches read as a smudge.
        float erosion = mix(0.4f, 1.6f, saturate(m.a));
        float shaped = saturate(fog + (n - 0.5f) * erosion * fog * (1.0f - fog));
        float a = saturate(0.66f * noiseTerm * shaped * breathing * mix(1.0f, 0.72f, hidden));

        // Hidden is a tint of real violet, the tape map's colour, not a grey veil over the thing
        // in front: half-mixed at 0.75 fog it read as a grey ghost over the bin.
        float3 chalk = float3(0xF7, 0xF5, 0xEF) / 255.0f;
        float3 cool = float3(0xD9, 0xE2, 0xEC) / 255.0f;
        float3 violet = float3(0xA4, 0x8A, 0xFA) / 255.0f;
        float3 color = mix(mix(chalk, cool, 0.2f), violet, 0.9f * hidden);

        float pulse = 1.0f - u.motion * 0.14f * (0.5f + 0.5f * sin(2.0f * M_PI_F * u.time / 1.8f));
        float r = saturate(0.28f * requested * noiseTerm * pulse);

        float3 rgb = color * a;
        rgb = u.requested.rgb * r + rgb * (1.0f - r);
        return float4(rgb, r + a * (1.0f - r));
    }

    // MARK: Dots

    struct Sprite {
        float4 a;  // world xyz, 1 for the halo sprite
        float4 b;  // birth time, from opacity, to opacity, opacity change time
        float4 c;  // edge since, death time, violet (0 or 1), unused
    };

    struct DotUniforms {
        float4x4 clip;
        float4 cameraAndTime;  // camera xyz, seconds
        float pointScale;      // pixels per point
        float reduceMotion;    // 1 drops the birth scale
        float2 pad;
    };

    struct DotOut {
        float4 position [[position]];
        float size [[point_size]];
        float4 color;
        float inner;  // radius fraction where the soft edge starts
    };

    constant float3 hologram = float3(0xE6, 0xEC, 0xF4) / 255.0f;
    constant float3 glow = float3(0x9C, 0xC8, 0xFF) / 255.0f;
    constant float3 violetDot = float3(0xB4, 0x9C, 0xFF) / 255.0f;

    vertex DotOut dotVertex(uint vid [[vertex_id]],
                            const device Sprite* sprites [[buffer(0)]],
                            constant DotUniforms& u [[buffer(1)]],
                            texture2d<float> mask [[texture(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        Sprite s = sprites[vid];
        float t = u.cameraAndTime.w;
        float birth = strongEaseOut((t - s.b.x) / 0.35f);
        float evidence = mix(s.b.y, s.b.z, strongEaseOut((t - s.b.w) / 0.25f));
        float fade = 1.0f - strongEaseOut((t - s.c.y) / 0.25f);
        float edge = strongEaseOut((t - s.c.x) / 0.25f);
        bool halo = s.a.w > 0.5f;
        bool violetOne = s.c.z > 0.5f;

        DotOut out;
        out.position = u.clip * float4(s.a.xyz, 1.0f);
        float fog = 1.0f;
        if (out.position.w > 0.05f) {
            float2 ndc = out.position.xy / out.position.w;
            fog = mask.sample(linear, float2(0.5f + 0.5f * ndc.x, 0.5f - 0.5f * ndc.y), level(0)).r;
        }
        float veil = violetOne ? 1.0f : mix(1.0f, 0.2f, saturate(fog));
        float alpha = evidence * birth * fade * veil;

        // Flat 3.5 pt and edge 5 pt from 4 m out, growing to 5 and 7.5 pt at 1 m. The prototype's
        // 2.5 to 4 pt over 1 to 2.5 m left dots at walking distance (1.5 to 3 m) as pinpricks.
        float far = clamp((length(s.a.xyz - u.cameraAndTime.xyz) - 1.0f) / 3.0f, 0.0f, 1.0f);
        float size = mix(mix(5.0f, 3.5f, far), mix(7.5f, 5.0f, far), edge);
        float inner = 0.7f;
        float3 color = hologram;
        if (halo) {
            // Edge 4x at 32%, flat 2.6x at 16%; a flat dot turning edge grows into it. The glow
            // is what makes the dots read as light; the prototype's 8% flat halo didn't show.
            size *= mix(2.6f, 4.0f, edge);
            alpha *= mix(0.16f, 0.32f, edge);
            inner = 0.0f;
            color = glow;
        }
        if (violetOne) { color = violetDot; }
        float scale = u.reduceMotion > 0.5f ? 1.0f : mix(0.6f, 1.0f, birth);

        if (alpha < 1.0f / 512.0f) { out.position = float4(0.0f, 0.0f, -1.0f, 1.0f); }
        out.size = size * scale * u.pointScale;
        // Alpha 0 with colour: added to what is under it, as light, when the layer composites.
        out.color = float4(color * alpha, 0.0f);
        out.inner = inner;
        return out;
    }

    fragment float4 dotFragment(DotOut in [[stage_in]], float2 pc [[point_coord]]) {
        float r = length(pc * 2.0f - 1.0f);
        return in.color * (1.0f - smoothstep(in.inner, 1.0f, r));
    }
    """
}
