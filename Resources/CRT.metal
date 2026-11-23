// CRT tube simulation. Compiled at runtime by the app, so you can tweak this
// file inside "SEE-RT.app/Contents/Resources" and relaunch to see changes.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;      // drawable size in pixels
    float2 contentSize;   // display size of the picture (aspect-corrected)
    float time;
    float lines;          // virtual scanline count
    float hres;           // virtual horizontal "pixels"
    float curvature;      // tube bulge
    float maskStrength;   // aperture-grille phosphor stripes
    float scanStrength;   // scanline darkness
    float squeezeX;       // power on/off collapse
    float squeezeY;
    float brightness;     // >1 flashes towards white (power line)
    float staticAmount;   // snow
    float fill;           // 0 = letterbox, 1 = crop to fill 4:3
    float contentLod;     // mip level matching the virtual resolution
    float vhs;            // 0..1 tape scan / pause distortion
    float vhsDir;         // +1 fast forward, -1 rewind (direction the noise bands crawl)
    float picBrightness;  // user picture control, 1 = neutral
    float picSaturation;  // user colour control, 1 = neutral, 0 = black & white
    float glow;           // phosphor bloom amount
    float grain;          // random noise amount
    float interlace;      // 1 = draw only one field (odd or even lines) per frame
    float field;          // which field this frame draws: 0 or 1
};

// The set's BRIGHT / COLOR knobs: applied to the video only, not the on-screen display.
static float3 adjust(float3 c, constant Uniforms& u) {
    float l = dot(c, float3(0.299, 0.587, 0.114));
    return max(mix(float3(l), c, u.picSaturation) * u.picBrightness, 0.0);
}

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut crt_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Map a 0..1 point on the 4:3 screen to the video texture (letterbox or crop).
static float2 contentUV(float2 suv, constant Uniforms& u, thread bool& inside) {
    float screenAspect = u.viewSize.x / u.viewSize.y;
    float contentAspect = u.contentSize.x / max(u.contentSize.y, 1.0);
    float ratio = contentAspect / screenAspect;
    float2 uv = suv;
    bool wide = ratio > 1.0;
    if (u.fill < 0.5) {
        if (wide) uv.y = (uv.y - 0.5) * ratio + 0.5;
        else      uv.x = (uv.x - 0.5) / ratio + 0.5;
    } else {
        if (wide) uv.x = (uv.x - 0.5) / ratio + 0.5;
        else      uv.y = (uv.y - 0.5) * ratio + 0.5;
    }
    inside = all(uv >= 0.0) && all(uv <= 1.0);
    return uv;
}

// `jit` is the tape wobble: it moves the video but not the TV's own on-screen display.
static float3 picture(float2 suv, float jit, texture2d<float> content, texture2d<float> osd,
                      sampler cs, sampler os, constant Uniforms& u) {
    bool inside;
    float2 cuv = contentUV(suv, u, inside);
    float3 c = inside ? adjust(content.sample(cs, cuv, level(u.contentLod)).rgb, u) : float3(0.0);
    float4 o = osd.sample(os, suv - float2(jit, 0.0));   // premultiplied on-screen display
    return c * (1.0 - o.a) + o.rgb;
}

static inline float beam(float d, float lum) {
    float w = mix(0.26, 0.46, lum);           // bright lines bloom wider
    return exp(-(d * d) / (2.0 * w * w));
}

fragment float4 crt_fragment(VOut in [[stage_in]],
                             constant Uniforms& u [[buffer(0)]],
                             texture2d<float> content [[texture(0)]],
                             texture2d<float> osd [[texture(1)]],
                             sampler cs [[sampler(0)]],
                             sampler os [[sampler(1)]]) {
    float2 uv = in.uv;
    float2 fc = in.pos.xy;

    // Tube curvature
    float2 cc = uv * 2.0 - 1.0;
    cc *= 1.0 + (cc.yx * cc.yx) * u.curvature;
    float2 cuv = cc * 0.5 + 0.5;
    float2 e = smoothstep(0.0, 0.005, cuv) * smoothstep(0.0, 0.005, 1.0 - cuv);
    float tube = e.x * e.y;

    // Power on/off collapse
    float2 sq = max(float2(u.squeezeX, u.squeezeY), float2(1e-4));
    float2 puv = (cuv - 0.5) / sq + 0.5;
    bool lit = u.squeezeX > 0.001 && all(puv >= 0.0) && all(puv <= 1.0);

    float3 col = float3(0.0);
    if (lit) {
        // VHS scan: tracking bands, per-line wobble, head-switching skew at the bottom
        float2 suv = puv;
        float vhs = u.vhs;
        float frame = floor(u.time * 30.0);
        float vband = 0.0;
        if (vhs > 0.001) {
            float line = floor(puv.y * u.lines);
            float jit = (hash12(float2(line, frame)) - 0.5) * 0.012 * vhs;
            for (int i = 0; i < 3; i++) {
                float speed = (0.35 + 0.22 * float(i)) * u.vhsDir;
                float by = fract(u.time * speed + float(i) * 0.37);
                float w = 0.02 + 0.025 * float(i);
                vband = max(vband, 1.0 - smoothstep(0.0, w, abs(puv.y - by)));
            }
            vband *= vhs;
            jit += vband * (hash12(float2(line * 1.7, frame + 3.0)) - 0.3) * 0.09;
            jit += smoothstep(0.93, 1.0, puv.y) * 0.05 * vhs;
            jit += sin(puv.y * 9.0 + u.time * 7.0) * 0.003 * vhs;
            suv.x += jit;
        }

        // Low-res raster: sample at virtual pixel centres on two neighbouring scanlines
        float ly = suv.y * u.lines - 0.5;
        float li = floor(ly);
        float fy = ly - li;
        float px = suv.x * u.hres - 0.5;
        float pi = floor(px);
        float fx = smoothstep(0.2, 0.8, px - pi);   // crisp-ish pixel edges
        float y0 = (li + 0.5) / u.lines, y1 = (li + 1.5) / u.lines;
        float x0 = (pi + 0.5) / u.hres,  x1 = (pi + 1.5) / u.hres;
        // slight convergence error: red/blue land a hair off
        float ca = (0.35 + 3.0 * vhs) / u.hres;
        float3 r0 = mix(picture(float2(x0, y0), suv.x - puv.x, content, osd, cs, os, u), picture(float2(x1, y0), suv.x - puv.x, content, osd, cs, os, u), fx);
        float3 r1 = mix(picture(float2(x0, y1), suv.x - puv.x, content, osd, cs, os, u), picture(float2(x1, y1), suv.x - puv.x, content, osd, cs, os, u), fx);
        r0.r = mix(r0.r, picture(float2(x0 + ca, y0), suv.x - puv.x, content, osd, cs, os, u).r, 0.5);
        r0.b = mix(r0.b, picture(float2(x1 - ca, y0), suv.x - puv.x, content, osd, cs, os, u).b, 0.5);

        // 480i: only this frame's field is lit; the other field is the previous frame
        // fading out (the persistence pass keeps it), which gives interlace twitter.
        if (u.interlace > 0.5) {
            r0 *= (abs(fmod(li, 2.0)) == u.field) ? 1.3 : 0.0;
            r1 *= (abs(fmod(li + 1.0, 2.0)) == u.field) ? 1.3 : 0.0;
        }

        float3 lw = float3(0.299, 0.587, 0.114);
        float3 scan = r0 * beam(fy, dot(r0, lw)) + r1 * beam(1.0 - fy, dot(r1, lw));
        float3 flat = mix(r0, r1, fy);
        col = mix(flat, scan * 1.45, u.scanStrength);

        // Phosphor glow
        bool gin;
        float2 guv = contentUV(suv, u, gin);
        if (gin) col += adjust(content.sample(cs, guv, level(u.contentLod + 3.0)).rgb, u) * u.glow;

        // Tape artefacts: washed-out chroma, white dropout streaks inside the bands
        if (vhs > 0.001) {
            float l = dot(col, lw);
            col = mix(col, float3(l), 0.4 * vhs);
            float seg = hash12(float2(floor(fc.x / 7.0), floor(suv.y * u.lines) + frame * 13.0));
            float streak = step(1.0 - 0.3 * vband - 0.004 * vhs, seg);
            col = mix(col, float3(0.92), streak * 0.85);
            col += vband * 0.15 * hash12(fc + frame);
        }

        // Aperture grille (vertical RGB phosphor stripes)
        float m = fmod(floor(fc.x), 3.0);
        float3 mask = float3(1.0 - u.maskStrength);
        if (m < 0.5) mask.r = 1.0; else if (m < 1.5) mask.g = 1.0; else mask.b = 1.0;
        col *= mask / (1.0 - u.maskStrength * 0.6667);

        // Snow
        float n = hash12(floor(fc / 2.0) + floor(u.time * 60.0) * 17.0);
        col = mix(col, float3(n * 0.9), u.staticAmount);

        // Hum bar, flicker, grain
        col *= 1.0 - 0.035 * (0.5 + 0.5 * sin((puv.y + u.time * 0.11) * 6.2831));
        col *= 1.0 + 0.012 * sin(u.time * 113.0);
        col += (hash12(fc + fract(u.time) * 917.0) - 0.5) * u.grain;

        // Power-line flash
        col = mix(col, float3(1.0), saturate(u.brightness - 1.0));
        col = pow(max(col, 0.0), float3(1.05));
    }

    // Vignette, glass tint, reflection
    float2 sc = saturate(cuv);
    float vig = pow(16.0 * sc.x * sc.y * (1.0 - sc.x) * (1.0 - sc.y), 0.2);
    col *= vig;
    col += float3(0.020, 0.024, 0.024);
    float2 rp = (uv - float2(0.27, 0.12)) * float2(1.0, 1.7);
    col += (1.0 - smoothstep(0.0, 0.6, length(rp))) * 0.05;
    col += smoothstep(0.85, 1.0, 1.0 - uv.y) * 0.015;

    // Outside the bulged glass: dark tube surround
    col = mix(float3(0.01), col, tube);
    return float4(col, 1.0);
}

// Phosphor persistence: each pixel is the brighter of this frame and the last
// frame faded. Green phosphor lingers a little longer than red and blue (P22-ish).
struct PersistOut {
    float4 screen [[color(0)]];
    float4 accum  [[color(1)]];
};

fragment PersistOut persist_fragment(VOut in [[stage_in]],
                                     constant float& decay [[buffer(0)]],
                                     texture2d<float> cur [[texture(0)]],
                                     texture2d<float> prev [[texture(1)]]) {
    uint2 p = uint2(in.pos.xy);
    float3 c = cur.read(p).rgb;
    float3 o = prev.read(p).rgb * (decay * float3(0.93, 1.0, 0.86));
    float4 r = float4(max(c, o), 1.0);
    PersistOut out;
    out.screen = r;
    out.accum = r;
    return out;
}
