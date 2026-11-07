#include <metal_stdlib>
using namespace metal;

struct CameraUniforms {
    float4x4 viewProjection;
    float4 viewportTimeScale;   // width, height, renderer-relative time, point scale
    float4 cameraPositionAndTier;
    float4 cameraRight;          // xyz = world-space camera right vector
    float4 cameraUp;             // xyz = world-space camera up vector; w = People context ring visibility [0,1]
    // x = field dim factor, y = Meaning-cluster visibility (1 visible,
    // 0 hidden; ramped by the lock transition's source warp),
    // z = People portrait context-dim phase,
    // w = transient hover-highlight lane, shared by two lens-exclusive
    //     consumers: hub index + 1 of the hovered People planet (orbit-path
    //     brighten), or the hovered Meaning cluster's phase + 1
    //     (nucleus / spike / gas flare, matched within ±5e-5). 0 = none.
    float4 lockControls;
    // Frame visual language flags. See MetalCameraUniforms.frameVisualLanguage:
    //   .x = density nebula  (0 off, 1 atmospheric)
    //   .y = action motion   (0 off, 1 current-only, 2 all-actionable)
    //   .z = pulse rest damp (1 = pulses at full amplitude while redraw is
    //        sustained, ramped to 0 at rest so pure time-driven brightness
    //        pulses freeze at their canonical midpoint, never mid-sine)
    //   .w = arc halos       (0 off, 1 ambient, 2 prominent)
    float4 frameVisualLanguage;
};

struct StarInstance {
    float4 positionRadius;
    float4 color;
    float4 signal;              // hover, selected, search, citation
    float4 effects;             // practical, arrival epoch, move magnitude, deletion
    float4 lock;                // lockFocus, glyphCode, emergeMask, peopleContextFade
    /// `xyz` = `defaultCorrespondentTint` baked CPU-side regardless of the
    /// active frame's coloration. The fragment shader overrides `in.color.rgb`
    /// with this tint when the node is triggered AND `emergeMask` contains
    /// the correspondentTint bit.
    /// `w` = People solar-system hub displacement lane (hub index + 1 into
    /// the shared displacement table; 0 = identity). Ring satellites ride
    /// their planet's orbital displacement and inherit its detail fade.
    float4 emerge;
};

/// Shared People solar-system displacement table. Entry 0 is the identity
/// (zero displacement, fade 1); entry i+1 belongs to hub i. `xyz` = the
/// hub's current orbital displacement off its packet base position, `w` =
/// the hub's Saturn-detail fade (rings + ring satellites) from the
/// planet's apparent size.

struct NebulaInstance {
    float4 positionRadius;
    float4 colorDensity;        // rgb, density
    float4 meta;                // member count, alpha, reserved, reserved
};

struct HaloInstance {
    float4 positionRadius;
    float4 colorIntensity;      // rgb, intensity
    float4 meta;                // source count, density, phase, reserved
    float4 lock;                // lock focus, reserved, reserved, reserved
};

struct FiberVertex {
    float3 from;
    float strength;
    float3 to;
    float strokeWidthPixels;
    float4 color;
    float4 lock;                // lock focus, edge kind, endpoint, side
};

// One Saturn-style ring band orbiting a correspondent hub in the `.people`
// galaxy layout. The vertex shader extends a quad in the ring's plane
// (perpendicular to `normal`) and the fragment shader computes polar `r`
// from the corner UV, discarding pixels outside the annular band. Layout
// mirrors `MetalPersonRingInstance` in `ConstellationMetalRenderer.swift`.
struct PersonRingInstance {
    float4 centerRadius;        // xyz = ring center, w = mid-line radius
    float4 normalThickness;     // xyz = ring plane normal (unit length), w = band half-width
    float4 colorAlpha;          // rgb = ring color, a = base alpha
    float4 accountColor;        // rgb = hub/account color, a = optional arc start fraction
    float4 tier;                // x = tier code, y = shimmer flag, z = radial glow material, w = optional arc end fraction
    float4 transition;          // x = fade with People context dim phase, y = deletion progress,
                                // z = hub displacement lane (index + 1; 0 = identity)
};

// One 3D person-hub planet — instanced over a shared procedural icosphere
// mesh. The vertex shader scales each unit-sphere vertex by `radius` and
// translates by `center`; the fragment shader does Lambert diffuse + Fresnel
// rim using a world-fixed light direction so planets at different positions
// in the galaxy show different lit hemispheres as the camera flies past.
// Mirrors `MetalPersonPlanetInstance` in `ConstellationMetalRenderer.swift`.
struct PersonPlanetInstance {
    float4 centerRadius;        // xyz = world center, w = radius
    float4 color;               // rgb = albedo, a = reserved
    float4 glyphUV;             // xy = atlas origin, zw = atlas size
    float4 signal;              // People: x = recencyScore, y = focusGlow,
                                //          z = wide glyph decal (two-line name),
                                //          w = negative deletion progress.
                                // Meaning: x = density [0,1], y = visible members,
                                //          z = static brightness phase (radians),
                                //          w = material (1 field / 2 core,
                                //          3 = the People solar system's sun).
    float4 orbital;             // x = hub displacement lane (index + 1; 0 = identity),
                                // y = petal-red ember intensity (open obligations),
                                // z/w reserved
};

struct PlanetOut {
    float4 position [[position]];
    float3 worldPos;
    float3 worldNormal;
    float4 color;
    float4 glyphUV;
    float4 signal;
    float4 orbital;
};

// One engraved orbit path (or recency band guide) in the People solar
// system. The vertex shader traces r(ν) = q(1+e)/(1+e·cos ν) around the
// sun-focus as an instanced line strip; the path itself is time-invariant
// so this pass never reads the displacement table. Layout mirrors
// `MetalPersonOrbitPathInstance` in `ConstellationMetalRenderer.swift`.
struct PersonOrbitPathInstance {
    float4 centerPeri;          // xyz = sun (focus) position, w = perihelion q
    float4 axisPE;              // xyz = unit perihelion axis P̂, w = eccentricity
    float4 axisQH;              // xyz = in-plane 90° axis Q̂ (inclination-tilted),
                                // w = hub displacement lane for hover matching
    float4 colorAlpha;          // rgb = whisper color, a = base alpha
    float4 style;               // x = style (0 orbit, 1 band guide, 2 comet/dashed),
                                // y = baked focus highlight
};

struct OrbitPathOut {
    float4 position [[position]];
    float4 color;
    float styleKind;
    float highlight;
    float pathT;
};

// Per-cluster instance for the Meaning-lens metaball body. Mirrors
// `MetalMeaningMetaballInstance` in ConstellationMetalRenderer.swift.
struct MeaningMetaballInstance {
    float4 centerRadius;        // xyz = world anchor (medoid), w = bounding radius
    float4 color;               // rgb = lens colour, a = density
    float4 memberRange;         // x = first index, y = blob count, z = phase,
                                // w = raymarch steps stamped per frame (<= 0 → 24)
};

// One member contribution in the shared metaball member buffer. Mirrors
// `MetalMeaningMetaballMember` in ConstellationMetalRenderer.swift.
struct MeaningMetaballMember {
    float4 positionRadius;      // xyz = world position, w = influence radius
};

// Vertex-to-fragment payload for the metaball pipeline. The fragment
// shader raymarches between two surface hits of the bounding sphere
// along the camera ray; everything it needs is carried here.
struct MetaballOut {
    float4 position [[position]];
    float3 worldPos;
    float3 worldCentroid;
    float boundingRadius;
    float4 color;
    float4 memberRange;
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float4 signal;
    float4 effects;
    float4 meta;
    float4 lock;
    /// Emerge channel: xyz = default correspondent tint, w = action ring
    /// code. Only the star vertex / fragment populate or consume this;
    /// every other pass (background, halo, nebula, fiber) leaves
    /// it zeroed so its render path is untouched by EmergeOnInteract.
    float4 emerge;
};

struct FiberOut {
    float4 position [[position]];
    float4 color;
    float strength;
    float lockFocus;
    /// Screen-space distance (in pixels) from this vertex's projected
    /// position to the focal pixel. Consumed by the Graph Bloom mechanism
    /// in the fiber fragment shader to drive a wavefront alpha gate.
};

constant float2 quadCorners[6] = {
    float2(-1.0, -1.0),
    float2( 1.0, -1.0),
    float2(-1.0,  1.0),
    float2( 1.0, -1.0),
    float2( 1.0,  1.0),
    float2(-1.0,  1.0)
};

static inline float lock_dim_multiplier(float lockFocus, constant CameraUniforms& uniforms) {
    float fieldDimFactor = saturate(uniforms.lockControls.x);
    return fieldDimFactor + (1.0 - fieldDimFactor) * saturate(lockFocus);
}

vertex float4 constellation_background_vertex(
    uint vid [[vertex_id]]
) {
    float2 p;
    if (vid == 0) {
        p = float2(-1.0, -1.0);
    } else if (vid == 1) {
        p = float2(3.0, -1.0);
    } else {
        p = float2(-1.0, 3.0);
    }
    return float4(p, 0.0, 1.0);
}

fragment float4 constellation_background_fragment() {
    float3 base = float3(0.018, 0.023, 0.033);
    return float4(base, 1.0);
}

vertex SpriteOut constellation_halo_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device HaloInstance* halos [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    HaloInstance halo = halos[iid];
    float3 source = halo.positionRadius.xyz;
    float4 center = uniforms.viewProjection * float4(source, 1.0);
    float2 corner = quadCorners[vid];
    float distance = max(length(source - uniforms.cameraPositionAndTier.xyz), 0.08);
    float proximity = clamp(1.25 / distance, 0.34, 2.45);
    float density = saturate(halo.meta.y);
    float pixelRadius = max(halo.positionRadius.w, 0.01)
        * uniforms.viewportTimeScale.w
        * proximity
        * (1.0 + density * 0.24);
    float pixelLimit = max(uniforms.viewportTimeScale.x, uniforms.viewportTimeScale.y) * 0.82;
    pixelRadius = min(pixelRadius, pixelLimit);
    float2 clipOffset = (corner * pixelRadius * 2.0 / max(uniforms.viewportTimeScale.xy, float2(1.0))) * max(center.w, 0.001);

    SpriteOut out;
    out.position = center + float4(clipOffset, 0.0, 0.0);
    out.uv = corner;
    out.color = float4(halo.colorIntensity.rgb, halo.colorIntensity.w * (0.72 + proximity * 0.28));
    out.signal = float4(0.0);
    out.effects = float4(0.0);
    out.meta = float4(halo.meta.x, density, halo.meta.z, proximity);
    out.lock = halo.lock;
    out.emerge = float4(0.0);
    return out;
}

fragment float4 constellation_halo_fragment(
    SpriteOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    float d = length(in.uv);
    if (d > 1.12) {
        discard_fragment();
    }

    float count = max(in.meta.x, 1.0);
    float density = saturate(in.meta.y);
    float phase = in.meta.z;
    float time = uniforms.viewportTimeScale.z;
    float proximity = clamp(in.meta.w, 0.34, 2.45);

    // Meaning-nucleus diffraction spikes — the stellar-core signature over
    // the cluster's small nucleus body. The quad is screen-aligned, so the
    // thin cross stays upright at any camera orientation. `meta.z` carries
    // the cluster's deterministic phase; a `lockControls.w` match
    // (phase + 1, see `setHoveredMeaningCluster`) is the transient hover
    // flare. Tagged by `lock.w = 1` from `meaningNucleusSpikeHalo`.
    if (in.lock.w > 0.5) {
        float clusterVisibility = saturate(uniforms.lockControls.y);
        if (clusterVisibility <= 0.001) {
            discard_fragment();
        }
        float hoverLane = uniforms.lockControls.w;
        float hovered = (hoverLane > 0.5 && abs(hoverLane - 1.0 - phase) < 0.00005) ? 1.0 : 0.0;
        float flare = 1.0 + 0.85 * hovered;
        // Needle-fine arms along the screen axes, linearly tapered so the
        // tips die before the quad edge.
        float armX = exp(-abs(in.uv.y) * 30.0) * saturate(1.0 - abs(in.uv.x) * 1.04);
        float armY = exp(-abs(in.uv.x) * 30.0) * saturate(1.0 - abs(in.uv.y) * 1.04);
        float arms = armX + armY;
        float core = exp(-d * d * 46.0);
        float bloom = exp(-d * d * 6.5);
        float dim = lock_dim_multiplier(0.0, uniforms);
        float3 white = float3(0.99, 0.99, 1.0);
        float3 color = (white * core * 1.10 + in.color.rgb * (arms * 0.80 + bloom * 0.26))
            * flare * dim;
        float alpha = (core * 0.80 + arms * 0.50 + bloom * 0.16)
            * in.color.a * flare * dim * clusterVisibility;
        return float4(color, saturate(alpha));
    }

    float edgeFade = smoothstep(1.12, 0.86, d);
    float cloud = exp(-d * d * (1.00 + density * 0.75));
    float core = exp(-d * d * (5.40 - density * 1.30));
    float ringA = smoothstep(0.060, 0.0, abs(d - (0.42 + 0.025 * sin(time * 0.22 + phase))));
    float ringB = smoothstep(0.075, 0.0, abs(d - (0.76 + 0.035 * sin(time * 0.15 + phase * 0.73))));
    float shimmer = 0.86 + 0.14 * sin(time * 0.35 + d * 12.0 + phase);
    float concentration = min(1.0, log2(count + 1.0) / 9.5);

    // Meaning-cluster orbs are translucent density fields, not solid node
    // bodies. The renderer tags them with lock.z so this branch can use a
    // softer radial falloff and a slow internal current without changing
    // message-star or Projects-nebula halos.
    if (in.lock.z > 0.5) {
        float angle = atan2(in.uv.y, in.uv.x);
        float softEdge = smoothstep(1.20, 0.72, d);
        float mist = exp(-d * d * (0.42 + density * 0.18));
        float coreGlow = exp(-d * d * (1.45 + density * 0.90));
        float currentA = smoothstep(
            0.070,
            0.0,
            abs(d - (0.34 + 0.055 * sin(time * 0.21 + phase)))
        );
        float currentB = smoothstep(
            0.085,
            0.0,
            abs(d - (0.68 + 0.070 * sin(time * 0.16 + phase * 0.61)))
        );
        float angularCurrent = pow(
            saturate(0.52 + 0.48 * cos(angle * 3.0 + time * 0.24 + phase)),
            2.0
        ) * exp(-d * d * 1.65);
        float breathing = 0.86 + 0.14 * uniforms.frameVisualLanguage.z * sin(time * 0.18 + phase);
        float envelope = (
            mist * 0.58
            + coreGlow * (0.16 + density * 0.16)
            + (currentA * 0.16 + currentB * 0.13 + angularCurrent * 0.12) * (0.45 + density * 0.85)
        ) * softEdge * breathing;
        float dim = lock_dim_multiplier(in.lock.x, uniforms);
        float alpha = saturate(envelope * in.color.a * (0.92 + density * 0.70)) * dim;
        float3 color = in.color.rgb * (0.92 + density * 0.55) * dim
            + float3(0.16, 0.18, 0.20) * (currentA + currentB) * 0.050 * dim;
        return float4(color, alpha);
    }

    // Nested-aspect inner ring — `.projects` frame draws a thin ring
    // inside the cluster halo when a secondary arc label covers ≥30 % of
    // remaining members. The flag is packed into `lock.y` by the
    // renderer (see `nebulaHaloInstance` in ConstellationMetalRenderer).
    // The ring lifts toward white so it reads as a distinct aspect inside
    // the parent halo's tint, rather than another shade of the parent.
    float nestedAspect = clamp(in.lock.y, 0.0, 1.0);
    float nestedRing = smoothstep(0.045, 0.0, abs(d - 0.55)) * nestedAspect;

    float envelope = (cloud * 0.26 + core * 0.18 + (ringA * 0.13 + ringB * 0.10) * (0.55 + density * 0.60))
        * edgeFade
        * shimmer;
    envelope += nestedRing * 0.22;
    float dim = lock_dim_multiplier(in.lock.x, uniforms);

    // Atmospheric density nebula — only when the active frame requests it
    // (FrameVisualLanguage.densityNebula == .atmospheric on `.meaning`).
    // Reads as terrain rather than activity: slow (~0.16 Hz), soft (0.78–1.00
    // multiplier), phase-offset per cluster via `meta.z` so neighbouring
    // halos don't pulse in lockstep.
    float atmospheric = step(0.5, uniforms.frameVisualLanguage.x);
    float atmosphericPulse = 0.78 + 0.22 * uniforms.frameVisualLanguage.z * sin(time * 0.16 + phase);
    float frameAlphaMod = mix(1.0, atmosphericPulse, atmospheric);

    float alpha = saturate(envelope * in.color.a * (0.82 + concentration * 0.42) * (0.82 + proximity * 0.16)) * dim * frameAlphaMod;
    float3 baseColor = in.color.rgb * (0.70 + density * 0.38 + concentration * 0.25) * dim;
    // Nudge the nested ring toward white so it visibly separates from the
    // halo's parent tint without becoming a foreign palette entry.
    float3 color = baseColor + nestedRing * float3(0.40, 0.42, 0.45) * dim;
    return float4(color, alpha);
}

vertex SpriteOut constellation_star_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device StarInstance* stars [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    const device float4* hubDisplacements [[buffer(2)]]
) {
    StarInstance star = stars[iid];
    // People solar system: ring satellites ride their hub's orbital
    // displacement and inherit its Saturn-detail fade. Lane 0 is the
    // identity entry, so every non-People star is untouched.
    int hubLane = int(star.emerge.w + 0.5);
    float4 hubEntry = hubDisplacements[max(0, hubLane)];
    float detailFade = hubLane > 0 ? saturate(hubEntry.w) : 1.0;
    float3 starWorld = star.positionRadius.xyz + (hubLane > 0 ? hubEntry.xyz : float3(0.0));
    float4 center = uniforms.viewProjection * float4(starWorld, 1.0);
    float2 corner = quadCorners[vid];
    float radius = max(star.positionRadius.w, 0.001);
    float signalBoost = max(max(star.signal.x, star.signal.y), max(star.signal.z, star.signal.w));
    // Birth supernova expands the quad so the chromatic shockwave has room
    // to travel beyond the body. The expansion factor follows the same
    // easeOutCubic the SwiftUI sandbox previewed, peaking at ~4× normal
    // pixel radius near birth=1.0. The fragment shader divides by this to
    // place the settled body back at its native size inside the bigger quad.
    float birth = star.effects.y;
    float birthExpansion = 1.0;
    if (birth > 0.0 && birth < 1.0) {
        float waveT = max(0.0, (birth - 0.10) / 0.85);
        float waveScale = 1.0 - pow(1.0 - clamp(waveT, 0.0, 1.0), 3.0);
        birthExpansion = 1.0 + waveScale * 3.0;
    }
    // Deletion expands the sprite footprint while the Event Horizon is active
    // so the black-disc/lensing collapse reads at both constellation scale and
    // in locked-node focus. The bell curve avoids an initial size pop and
    // returns to the native footprint as the disc vanishes.
    float deletion = star.effects.w;
    float deathExpansion = 1.0;
    if (deletion > 0.0) {
        float deathT = clamp(deletion / 0.92, 0.0, 1.0);
        float deathFootprintBoost = max(0.0, star.effects.z);
        deathExpansion = 1.0 + sin(3.14159265 * deathT) * (0.85 + deathFootprintBoost);
    }
    float pixelRadius = radius * uniforms.viewportTimeScale.w * (1.0 + signalBoost * 0.55) * birthExpansion * deathExpansion;
    float2 clipOffset = (corner * pixelRadius * 2.0 / max(uniforms.viewportTimeScale.xy, float2(1.0))) * max(center.w, 0.001);

    SpriteOut out;
    out.position = center + float4(clipOffset, 0.0, 0.0);
    out.uv = corner;
    // Detail fade folds into the instance alpha so every fragment branch
    // (settled body, birth shockwave, deletion collapse) fades uniformly
    // as the parent planet's apparent size shrinks below legibility.
    out.color = float4(star.color.rgb, star.color.a * detailFade);
    out.signal = star.signal;
    out.effects = star.effects;
    out.meta = float4(radius, pixelRadius, birthExpansion, 0.0);
    out.lock = star.lock;
    out.emerge = star.emerge;
    return out;
}

fragment float4 constellation_star_fragment(
    SpriteOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    float d = length(in.uv);
    if (d > 1.35) {
        discard_fragment();
    }

    float tier = uniforms.cameraPositionAndTier.w;
    float hover = in.signal.x;
    float selected = in.signal.y;
    float search = in.signal.z;
    float citation = in.signal.w;
    float practical = in.effects.x;
    float birth = in.effects.y;
    float move = in.effects.z;
    float deletion = in.effects.w;
    float birthExpansion = max(in.meta.z, 1.0);

    float now = uniforms.viewportTimeScale.z;
    // Pure temporal brightness pulses scale their sine by the rest damp:
    // at rest each holds its canonical midpoint instead of freezing at an
    // arbitrary phase, and the amplitude ramps back in on wake so the
    // wall-clock phase jump never lands on screen.
    float pulseDamp = uniforms.frameVisualLanguage.z;
    float movePulse = smoothstep(0.015, 0.12, move) * (pulseDamp * sin(now * 7.0 + in.meta.x * 73.0) * 0.5 + 0.5);
    float searchPulse = search * (0.62 + 0.38 * pulseDamp * sin(now * 5.5));
    float citationPulse = citation * (0.58 + 0.42 * pulseDamp * sin(now * 4.0 + 1.7));
    float selectedPulse = selected * (0.75 + 0.25 * pulseDamp * sin(now * 2.2));
    float hoverPulse = hover * 0.45;
    float practicalPulse = practical * (0.45 + 0.25 * pulseDamp * sin(now * 3.1));
    float effectScale = tier >= 1.0 ? 0.55 : 1.0;

    // The settled-body radius lives in d ∈ [0, 1.35] when the quad is at
    // its native size. During birth the quad grows by `birthExpansion`, so
    // the body's effective coordinate is `d * birthExpansion` — once that
    // crosses 1.35 we're outside the body envelope and the fragment is in
    // the shockwave annulus.
    float dBody = d * birthExpansion;
    float core = smoothstep(0.74, 0.0, dBody);
    // Tightened Gaussian (was 2.8) so the halo collapses to the body
    // rather than smearing past it. At d=1.0 the halo is now ~0.7%
    // (was ~6%), which reads as a crisp disc instead of a soft fuzz —
    // critical for the big person-hub planets, harmless for the tiny
    // message stars where the halo was already only a few pixels wide.
    float halo = exp(-dBody * dBody * 5.0);
    float ring = smoothstep(0.075, 0.0, abs(dBody - 0.82));
    float dim = lock_dim_multiplier(in.lock.x, uniforms);
    // People-portrait background ring satellites (lock.w = 1) fade with
    // the `peopleContextDimPhase` ramp that recedes the background hub
    // bodies — out during focus entry, back in as the exit camera pulls
    // back. Unlike the context ring BANDS (which ride the separate
    // cameraUp.w channel and stay hidden through exit), these satellites
    // DO exist in the unlocked galaxy as ordinary stars, so restoring
    // them with the dim is what keeps the settled-packet swap free of
    // node popping. Folding the fade into `dim` covers the settled,
    // birth, and deletion branches alike.
    dim *= mix(1.0, 0.0, saturate(uniforms.lockControls.z) * saturate(in.lock.w));

    if (deletion > 0.0) {
        // Event Horizon collapse — narrative phases:
        //   [0.00, 0.65]: star body shrinks, halo fades
        //   [0.15, 0.85]: black disc grows past the star, covering the body
        //   [0.30, 0.85]: cyan Einstein lensing ring blooms then fades
        //   [0.85, 1.00]: black disc collapses radially; alpha vanishes
        float bodyShrink = 1.0 - clamp(deletion / 0.65, 0.0, 1.0);
        float discRadius = deletion < 0.85
            ? (deletion / 0.85) * 1.05
            : 1.05 * (1.0 - (deletion - 0.85) / 0.15);
        // Smooth disc coverage with a 0.04-uv softness band so it's not a
        // hard pixel edge. Soft-step is reversed so 1 = inside, 0 = outside.
        float discCover = smoothstep(discRadius + 0.02, discRadius - 0.02, d);
        float lensT = clamp((deletion - 0.30) / 0.55, 0.0, 1.0);
        float lensBell = sin(3.14159265 * lensT);
        float lensRing = smoothstep(0.06, 0.0, abs(d - 0.82)) * lensBell;
        float vanish = 1.0 - smoothstep(0.92, 1.0, deletion);

        float3 dimmedBody = in.color.rgb * (core * bodyShrink + halo * 0.55 * bodyShrink);
        // Lens ring borrows the dying star's own hue so the flare reads as
        // the account's identity bending its own light, not a generic cool tone.
        float3 visualColor = dimmedBody + in.color.rgb * lensRing * 1.30;
        float3 finalColor = mix(visualColor, float3(0.0, 0.0, 0.0), discCover) * dim;

        float bodyAlpha = (core + halo * 0.45) * in.color.a * bodyShrink * (1.0 - discCover);
        float discAlpha = discCover;
        float ringAlpha = lensRing * 0.85;
        float deathAlpha = saturate(bodyAlpha + discAlpha + ringAlpha) * vanish * dim;
        return float4(finalColor, deathAlpha);
    }

    if (birth > 0.0 && birth < 1.0) {
        // Supernova shockwave — narrative phases (matches the design
        // sandbox tile):
        //   [0.00, 0.18]: bright white flash core expands fast
        //   [0.10, 0.95]: chromatic shockwave ring travels outward; red
        //                 lags slightly inside, white at center, cyan
        //                 leads slightly outside (gravitational chromatic
        //                 aberration)
        //   [0.55, 1.00]: the settled body fades in inside the shockwave
        float p = birth;

        // Initial flash — a soft white core that pops fast then fades.
        float flashT = p < 0.18 ? p / 0.18 : 1.0;
        float flashOpacity = p < 0.30 ? 1.0 - p / 0.30 : 0.0;
        float flashCore = exp(-d * d * (8.0 / max(flashT * flashT, 0.04)));

        // Shockwave ring — the ring's normalized radius rides easeOutCubic
        // from 0 → ~1.0 over [0.10, 0.95]. We're inside an expanded quad
        // so d ∈ [0, 1.35] still maps to the visible area; the ring lands
        // near d=1.0 at peak.
        float waveT = max(0.0, (p - 0.10) / 0.85);
        float waveTC = clamp(waveT, 0.0, 1.0);
        float waveScale = 1.0 - pow(1.0 - waveTC, 3.0);
        float waveOpacity = max(0.0, 1.0 - waveTC) * 0.95;

        float ringWidth = 0.05;
        float redD   = abs(d - waveScale * 0.96);
        float whiteD = abs(d - waveScale);
        float tailD  = abs(d - waveScale * 1.04);
        float redRing   = smoothstep(ringWidth, 0.0, redD);
        float whiteRing = smoothstep(ringWidth, 0.0, whiteD);
        float tailRing  = smoothstep(ringWidth, 0.0, tailD);

        // Red leading edge stays as gravitational chromatic aberration (red-shifted
        // physics half of the effect). The trailing edge borrows the new star's
        // own hue so birth bursts express the account's identity.
        float3 redColor   = float3(1.00, 0.40, 0.30);
        float3 whiteColor = float3(1.00, 1.00, 1.00);
        float3 tailColor  = in.color.rgb;

        float3 burstColor = redColor * redRing * 0.70
            + whiteColor * whiteRing
            + tailColor * tailRing * 0.75;
        float burstAlpha = (redRing + whiteRing + tailRing * 0.85) * waveOpacity;

        float3 flashColor = whiteColor * flashCore * flashOpacity;

        // Settled body fades in over [0.55, 1.00]. dBody is the normalized
        // body coordinate inside the expanded quad.
        float settleT = clamp((p - 0.55) / 0.45, 0.0, 1.0);
        float3 bodyColor = in.color.rgb * (core + halo * 0.70) * settleT;
        float bodyAlpha = (core + halo * 0.45) * in.color.a * settleT;

        float3 finalColor = (burstColor + flashColor + bodyColor) * dim;
        float finalAlpha = saturate(burstAlpha + flashCore * flashOpacity + bodyAlpha) * dim;
        return float4(finalColor, finalAlpha);
    }

    float signal = max(max(searchPulse, citationPulse), max(selectedPulse, hoverPulse));
    signal = max(signal, practicalPulse);
    float emission = 1.0 + effectScale * (movePulse * 0.55) + signal * 2.2;
    float3 signalTint = float3(
        max(searchPulse, selectedPulse) * 0.95 + citationPulse * 0.30,
        citationPulse * 0.85 + practicalPulse * 0.45,
        searchPulse * 0.35 + selectedPulse * 0.75 + hoverPulse * 0.4
    );

    // Inside a locked context — People-lens locked-correspondent
    // satellites and any live lock's graded neighbourhood — strip the
    // magenta R+B signal halo. The body still
    // pulses through `emission` (which `signal` boosts) so the dot or open
    // ring continues to breathe in time; only the colored glow around it
    // is suppressed. The 0.45 threshold sits safely below the farthest
    // neighbour grade (0.50 — see
    // `LockedNeighborhoodSelection.farthestNeighbourFocusGrade` in
    // ConstellationRenderPlanner.swift) so every graded member of the
    // locked neighbourhood is stripped uniformly, while non-members
    // (lockFocus = 0) keep their search/citation halos.
    signalTint *= 1.0 - step(0.45, in.lock.x);

    // FrameVisualLanguage glyph variant (see Glyph.encode in
    // FrameVisualLanguage.swift for the stable wire format).
    //   0 = filled dot     (baseline; `.dot` / `.directional` received-direct).
    //   1 = hollow ring    (`.directional` sent-direct).
    //   2 = filled dashed  (`.directional` received-included on the People
    //                       hub; set per-placement by `PeopleGraphBuilder`).
    //   3 = hollow dashed  (`.directional` sent-included; same).
    //
    // The dashed pattern modulates the rim alpha by a 6-segment angular
    // sweep around the sprite — six visible arcs / six gaps. Six was picked
    // because it's coarse enough to read as an intentional dash at the
    // small sprite scales used at typical camera distance, while still
    // reading as "broken" rather than as a solid ring with one missing
    // arc.
    float glyphCode = in.lock.y;
    float bodyCore = core;
    float bodyHalo = halo;

    if (glyphCode > 0.5 && glyphCode < 1.5) {
        // Code 1 — hollow ring: replace the filled core with a tighter
        // outline band so the sent direction reads as an open mark while
        // still wearing the account's hue. Sits a little inside the
        // sprite radius (~0.51 of full extent) so the ring reads as a
        // restrained mark rather than a full-sprite halo.
        bodyCore = smoothstep(0.15, 0.0, abs(dBody - 0.51)) * 1.40;
        bodyHalo *= 0.55;
    } else if (glyphCode > 1.5 && glyphCode < 2.5) {
        // Code 2 — filled dashed: keep the filled body so the dot still
        // reads as "received," then overlay a dashed rim at the outer
        // edge so the eye picks up "included" as a secondary signal.
        float angle = atan2(in.uv.y, in.uv.x);
        float dashMask = smoothstep(0.0, 0.20, sin(angle * 6.0));
        float rim = smoothstep(0.10, 0.0, abs(dBody - 0.78)) * 1.15;
        bodyCore += rim * dashMask;
        bodyHalo *= 0.85;
    } else if (glyphCode > 2.5 && glyphCode < 3.5) {
        // Code 3 — hollow dashed: same hollow-ring band as code 1, but
        // modulated by the dash mask so the ring breaks into six arcs.
        float angle = atan2(in.uv.y, in.uv.x);
        float dashMask = smoothstep(0.0, 0.20, sin(angle * 6.0));
        bodyCore = smoothstep(0.15, 0.0, abs(dBody - 0.51)) * 1.40 * dashMask;
        bodyHalo *= 0.55;
    }

    // EmergeOnInteract — when this node is hovered / selected (locked) /
    // search-matched, suppressed visual channels re-acquire transiently.
    // The wire format mirrors `FrameVisualLanguage.EmergeOnInteract.rawValue`:
    //   bit 0 (= 1)  = correspondentTint  → swap body colour to People-tint
    //   bit 1 (= 2)  = threadStrand       → handled in fibres, not here
    //   bit 2 (= 4)  = arcHaloLabel       → handled in halos, not here
    //   bit 3 (= 8)  = temporalContext    → handled in fibres, not here
    //
    // Bit 4 (`actionState`, the old state-ringed triage decoration) was
    // retired alongside `Glyph.stateRinged` — included tier on the People
    // hub is now communicated by the dashed glyph variants above, not by
    // a hover-only colored ring.
    float3 bodyColor = in.color.rgb;
    float trigger = max(max(in.signal.x, in.signal.y), in.signal.z);
    int emergeMask = int(in.lock.z + 0.5);
    bool isTriggered = trigger > 0.001;

    if (isTriggered && (emergeMask & 1) != 0) {
        float3 emergeTint = in.emerge.xyz;
        if (emergeTint.x + emergeTint.y + emergeTint.z > 0.01) {
            // Mix toward the People-frame tint at 0.85 — strong enough that
            // the relationship cluster identity reads clearly while keeping
            // some account-hue continuity so the emerge isn't a hard swap.
            bodyColor = mix(bodyColor, emergeTint, 0.85);
        }
    }

    float3 color = bodyColor * (bodyCore * emission + bodyHalo * 0.70)
        + signalTint * (ring + bodyHalo * 0.35);
    color *= dim;
    float alpha = (bodyCore + bodyHalo * 0.45 + ring * signal * 0.45)
        * in.color.a * dim;
    return float4(color, saturate(alpha));
}

vertex SpriteOut constellation_nebula_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device NebulaInstance* nebulae [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    NebulaInstance nebula = nebulae[iid];
    float3 nebulaWorld = nebula.positionRadius.xyz;
    float4 center = uniforms.viewProjection * float4(nebulaWorld, 1.0);
    float2 corner = quadCorners[vid];
    float radius = max(nebula.positionRadius.w, 0.01);
    float pixelRadius = radius * uniforms.viewportTimeScale.w * 0.92;
    float2 clipOffset = (corner * pixelRadius * 2.0 / max(uniforms.viewportTimeScale.xy, float2(1.0))) * max(center.w, 0.001);

    SpriteOut out;
    out.position = center + float4(clipOffset, 0.0, 0.0);
    out.uv = corner;
    out.color = float4(nebula.colorDensity.rgb, nebula.meta.y);
    out.signal = float4(0.0);
    out.effects = float4(0.0);
    out.meta = float4(nebula.colorDensity.w, nebula.meta.x, radius, 0.0);
    out.lock = float4(0.0);
    out.emerge = float4(0.0);
    return out;
}

fragment float4 constellation_nebula_fragment(
    SpriteOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    float d = length(in.uv);
    if (d > 1.25) {
        discard_fragment();
    }
    float density = saturate(in.meta.x);
    float count = max(in.meta.y, 1.0);
    float time = uniforms.viewportTimeScale.z;
    float angle = atan2(in.uv.y, in.uv.x);
    float dust = 0.55 + 0.45 * sin(angle * 3.0 + d * 9.0 + time * 0.20 + count * 0.017);
    float cloud = exp(-d * d * (1.15 + density * 1.3));
    float core = exp(-d * d * 4.2) * density;
    float dim = lock_dim_multiplier(0.0, uniforms);
    float alpha = (cloud * 0.20 + core * 0.35) * in.color.a * (0.65 + dust * 0.35) * dim;
    float3 color = in.color.rgb * (cloud * (0.35 + density) + core * 1.4) * dim;
    return float4(color, saturate(alpha));
}

vertex FiberOut constellation_fiber_vertex(
    uint vid [[vertex_id]],
    const device FiberVertex* vertices [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    FiberVertex item = vertices[vid];
    float3 fromWorld = item.from;
    float3 toWorld = item.to;
    float4 fromClip = uniforms.viewProjection * float4(fromWorld, 1.0);
    float4 toClip = uniforms.viewProjection * float4(toWorld, 1.0);
    float endpoint = saturate(item.lock.z);
    float side = item.lock.w < 0.0 ? -1.0 : 1.0;
    float4 clip = mix(fromClip, toClip, endpoint);
    FiberOut out;

    // Per-edge-kind tint pre-mixed in the vertex stage so the fragment
    // shader stays unchanged. Code packed in `lock.y` by the renderer
    // (see `VectorEdgeKind.rendererCode` in OhiaCore). `0` (cosine /
    // un-annotated) keeps the existing blue baseline.
    int kind = int(item.lock.y + 0.5);
    float3 kindTint;
    if (kind == 1)      kindTint = float3(0.95, 0.65, 0.35);   // thread: warm amber
    else if (kind == 2) kindTint = float3(0.45, 0.78, 0.28);   // correspondent: leaf-green
    else if (kind == 3) kindTint = float3(0.40, 0.62, 0.95);   // temporal: cool blue
    else if (kind == 4) kindTint = float3(0.95, 0.42, 0.18);   // action: orange
    else if (kind == 5) kindTint = float3(0.62, 0.45, 0.85);   // category: lavender
    else if (kind == 6) kindTint = float3(0.85, 0.32, 0.65);   // arc: magenta
    else                kindTint = item.color.rgb;             // cosine — keep baseline blue
    float3 mixed = mix(item.color.rgb, kindTint, kind == 0 ? 0.0 : 0.65);
    out.color = float4(mixed, item.color.a);
    out.strength = item.strength;
    out.lockFocus = item.lock.x;
    float2 viewport = max(uniforms.viewportTimeScale.xy, float2(1.0));
    float2 fromNDC = fromClip.xy / max(fromClip.w, 0.001);
    float2 toNDC = toClip.xy / max(toClip.w, 0.001);
    float2 fromPixel = float2(
        (fromNDC.x * 0.5 + 0.5) * viewport.x,
        (1.0 - (fromNDC.y * 0.5 + 0.5)) * viewport.y
    );
    float2 toPixel = float2(
        (toNDC.x * 0.5 + 0.5) * viewport.x,
        (1.0 - (toNDC.y * 0.5 + 0.5)) * viewport.y
    );
    float2 direction = toPixel - fromPixel;
    if (length(direction) < 0.001) {
        direction = float2(1.0, 0.0);
    }
    float2 normalPixel = normalize(float2(-direction.y, direction.x));
    float halfWidth = max(item.strokeWidthPixels, 1.0) * 0.5;
    float2 ndcOffset = float2(
        normalPixel.x * 2.0 / viewport.x,
        -normalPixel.y * 2.0 / viewport.y
    ) * halfWidth * side;
    clip.xy += ndcOffset * clip.w;
    out.position = clip;
    return out;
}

fragment float4 constellation_fiber_fragment(
    FiberOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    float dim = lock_dim_multiplier(in.lockFocus, uniforms);
    float baseAlpha = in.color.a;
    float3 baseColor = in.color.rgb * (0.60 + in.strength * 0.90);

    return float4(baseColor * dim, baseAlpha * dim);
}

// MARK: - Person ring pass (`.people` Saturn rings)
//
// Each instance is a world-oriented quad in the ring's plane, sized to fit
// the outer band (radius + thickness). The fragment shader computes polar
// distance from center in the ring's local coords and discards anything
// outside `[radius - thickness, radius + thickness]`, fading alpha at the
// inner and outer edges. The whole pass sits between the halo and star
// passes so message-star billboards render on top of their orbital bands.

vertex SpriteOut constellation_person_ring_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device PersonRingInstance* rings [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    const device float4* hubDisplacements [[buffer(2)]]
) {
    PersonRingInstance ring = rings[iid];
    // Ride the hub's orbital displacement; inherit its Saturn-detail fade.
    int hubLane = int(ring.transition.z + 0.5);
    float4 hubEntry = hubDisplacements[max(0, hubLane)];
    float detailFade = hubLane > 0 ? saturate(hubEntry.w) : 1.0;
    float3 center = ring.centerRadius.xyz + (hubLane > 0 ? hubEntry.xyz : float3(0.0));
    float radius = max(ring.centerRadius.w, 0.0001);
    float thickness = max(ring.normalThickness.w, 0.0001);
    float halfExtent = radius + thickness * 2.0;

    // Build two orthonormal in-plane axes from the ring normal so the quad
    // lies on the ring's plane in world space. The first axis is biased
    // toward world-X (or world-Y if the normal already points near X) so
    // every ring shares a consistent on-disc orientation — the galaxy reads
    // as a coherent plane instead of a scatter of arbitrarily-rotated rings.
    float3 n = normalize(ring.normalThickness.xyz);
    float3 reference = (abs(n.x) < 0.9) ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0);
    float3 axisU = normalize(cross(reference, n));
    float3 axisV = normalize(cross(n, axisU));

    float2 corner = quadCorners[vid];
    float3 offset = axisU * (corner.x * halfExtent) + axisV * (corner.y * halfExtent);
    float3 worldPos = center + offset;

    SpriteOut out;
    out.position = uniforms.viewProjection * float4(worldPos, 1.0);
    // UV scaled to [-halfExtent, +halfExtent] in world units so the
    // fragment can read polar distance directly.
    out.uv = corner * halfExtent;
    out.color = ring.colorAlpha;
    // `signal` carries the hub's AccountColor. The Twilight palette
    // remains the base tier fill; focused overlays use the account hue as a
    // restrained inner radiance so the planet's light reaches the bands
    // without filling the Cassini gaps. Its alpha is reserved as the arc
    // start for segmented ring variants; account color stays on the orb.
    out.signal = ring.accountColor;
    // meta.x = mid-line radius, meta.y = half-width thickness,
    // meta.z = tier code, meta.w = shimmer flag (0/1)
    out.meta = float4(radius, thickness, ring.tier.x, ring.tier.y);
    // lock.x carries the arc end for segmented ring variants; lock.y marks
    // transition-only People context rings that fade with the focused portrait;
    // lock.z carries final-hub deletion progress; lock.w carries the
    // planet's Saturn-detail fade (apparent-size LOD).
    out.lock = float4(ring.tier.w, ring.transition.x, ring.transition.y, detailFade);
    out.emerge = float4(0);
    // effects.x = radial glow material (0/1)
    out.effects = float4(ring.tier.z, 0, 0, 0);
    return out;
}

fragment float4 constellation_person_ring_fragment(
    SpriteOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    float r = length(in.uv);
    float radius = in.meta.x;
    float thickness = in.meta.y;
    float bandHalf = thickness;
    float signedOffset = r - radius;             // [-bandHalf, +bandHalf] inside the band
    float distanceFromCenter = abs(signedOffset);
    // Hard discard at the exact geometric band edge — no Gaussian
    // overscan into the adjacent Cassini gap. The visible band
    // boundary IS the geometric boundary, so neighbouring rings read
    // as discretely separate even when the gap is small.
    if (distanceFromCenter > bandHalf) {
        discard_fragment();
    }
    // Normalized position across the band ([-1, +1]). -1 = band inner
    // edge (toward planet), +1 = band outer edge (away from planet).
    float bandT = clamp(signedOffset / max(bandHalf, 0.0001), -1.0, 1.0);
    float arcEnd = in.lock.x;
    if (arcEnd > 0.0) {
        float arcStart = clamp(in.signal.a, 0.0, 1.0);
        arcEnd = clamp(arcEnd, 0.0, 1.0);
        float theta = atan2(in.uv.y, in.uv.x);
        float fraction = theta / 6.2831853;
        if (fraction < 0.0) {
            fraction += 1.0;
        }
        bool insideArc = arcEnd >= arcStart
            ? (fraction >= arcStart && fraction <= arcEnd)
            : (fraction >= arcStart || fraction <= arcEnd);
        if (!insideArc) {
            discard_fragment();
        }
    }
    if (in.effects.x > 0.5) {
        float innerEdge = radius - bandHalf;
        float outerEdge = radius + bandHalf;
        float glowT = saturate((r - innerEdge) / max(outerEdge - innerEdge, 0.0001));
        float outwardFade = pow(1.0 - glowT, 0.82);
        float outerDissolve = 1.0 - smoothstep(0.82, 1.0, glowT);
        float now = fmod(uniforms.viewportTimeScale.z, 4096.0);
        float breath = 0.94 + 0.06 * uniforms.frameVisualLanguage.z * sin(now * 1.25);
        float2 radialDir = in.uv / max(r, 0.0001);
        float orbitalLight = 0.58 + 0.42 * smoothstep(-0.35, 1.0, dot(radialDir, normalize(float2(0.42, 0.72))));
        float3 accountLight = clamp(in.signal.rgb * (1.45 + (1.0 - glowT) * 0.75) + float3(0.035), 0.0, 1.0);
        accountLight = mix(accountLight * 0.62, accountLight, orbitalLight);
        float alpha = in.color.a * outwardFade * outerDissolve * breath * saturate(in.lock.w);
        return float4(accountLight, saturate(alpha));
    }
    // Two-layer envelope reading as a translucent Saturn band:
    //   * `body`       — flat top-hat with a thin 18% edge feather,
    //                    rendered at moderate alpha so the void shows
    //                    through the band the way it does on real
    //                    planetary rings.
    //   * `centerLine` — a sharply defined hairline spine down the
    //                    middle of the band, falling off in the inner
    //                    4% of the half-band so it reads as a crisp
    //                    line rather than a diffuse glow. Carries the
    //                    band's primary visual weight (0.55 of the
    //                    envelope) so the ring is unambiguously
    //                    centered even when the body is translucent.
    // Body edge tightened from 18% feather → 4% feather so the band
    // ends abruptly at its geometric edge. The previous wide feather
    // was bleeding the band tone inward toward the orb, eating the
    // visible black gap between the orb rim and the first ring.
    float body = 1.0 - smoothstep(0.96, 1.0, abs(bandT));
    float centerLine = 1.0 - smoothstep(0.0, 0.04, abs(bandT));
    // Locked-focus rings get an even-harder inner spine — a thinner,
    // sharper core layered on top of the baseline centerLine so the
    // focused correspondent's bands read with a tighter mid-line than
    // the surrounding unfocused hubs.
    float focusedLineCore = 1.0 - smoothstep(0.018, 0.038, abs(bandT));
    // Body carries the band's bulk weight; the spine contributes a
    // thinner, defined line through the band's mid-radius so the ring
    // reads as unambiguously centered even with the body open and
    // translucent.
    float envelope = body * 0.55 + centerLine * 0.30;
    // Rings are NOT dimmed by the generic locked-overlay field-dim factor.
    // The People-lens inspector opens for any node (an email node or a
    // correspondent orb), and in every case the user wants to read the locked
    // hub's own ring structure. The one exception is a People portrait's
    // background context rings: those are transition continuity geometry.
    // They follow the dedicated visibility channel (cameraUp.w) — fading
    // out with the entry recede but staying hidden through the exit
    // pullback, because the unlocked galaxy renders no ring systems and
    // fading them back in would bloom rings on every background hub only
    // to snap them away at the settled-packet swap.
    float contextRingVisibility = saturate(uniforms.cameraUp.w);
    float dim = in.lock.y > 0.5 ? contextRingVisibility : 1.0;

    // Focused-correspondent's rings in the People lens's locked-node
    // overlay are encoded by `meta.w` (0 = unfocused, 1 = focused).
    // The focused state lifts the band envelope, sharpens the inner
    // spine, and rides a clockwise trim-sweep glisten along that
    // spine — see the `trimSweep` block below. A locked correspondent
    // is shown alone and so loses the visual reinforcement of many
    // overlapping People rings; the boosted static envelope keeps the
    // focused bands present between glisten passes.
    float shimmerFlag = in.meta.w;
    float focusedRing = shimmerFlag > 0.5 ? 1.0 : 0.0;
    float focusedEnvelope = body * 0.72 + centerLine * 0.22 + focusedLineCore * 0.82;
    envelope = mix(envelope, max(envelope, focusedEnvelope), focusedRing);

    // Trim-sweep glisten: a short bright-white arc segment rotates
    // clockwise around the focused ring's spine at a constant angular
    // rate, with a per-cycle opacity envelope (fade in → hold → fade
    // out) that loops continuously with no pause between cycles. The
    // four rings (`ringTier` 0–3) phase-stagger by `T/4` so they
    // chase each other around their respective bands rather than
    // sweeping in unison.
    //
    // Translated from the SwiftUI `Circle().trim(0, 0.05).stroke(...)`
    // + `.rotationEffect(.degrees(θ))` idiom:
    //   * trim(0, 0.05) -> angular Gaussian, sigma ~= 0.09 rad ~= 5° HWHM
    //   * rotationEffect(θ) clockwise -> theta_c = +2*pi * cyclePhase
    //     (ring +Y projects to camera up, so positive angular velocity
    //     reads clockwise on screen)
    //   * opacity 0 -> 1 -> 0 -> smoothstep ramps at 25% / 75% of cycle
    //   * no-pause repeat -> fmod(t, T) with no gap between cycles
    //   * constant rate -> linear cyclePhase, no easeInOut on theta_c
    float trimSweep = 0.0;
    if (shimmerFlag > 0.5) {
        float now = fmod(uniforms.viewportTimeScale.z, 4096.0);
        float ringTier = in.meta.z;
        float cyclePeriod = 1.60;                       // seconds per revolution
        float phaseOffset = ringTier * 0.25;            // T/4 stagger across 4 rings
        float cyclePhase = fmod((now / cyclePeriod) - phaseOffset, 1.0);
        if (cyclePhase < 0.0) cyclePhase += 1.0;

        // Sweep direction follows the chronological order of email
        // nodes on the ring (oldest → newest), matching the angular
        // ordering set by `PeopleGraphBuilder.chronologicalRingAngle`.
        // The sign on `cyclePhase` is negated so the arc travels in
        // the same on-screen direction the satellites are laid out
        // through time, rather than against it. atan2(sin, cos) wraps
        // the angular delta to (-pi, pi] without an explicit modulo.
        float sweepAngle = -cyclePhase * 6.2831853;
        float theta = atan2(in.uv.y, in.uv.x);
        float dAngle = theta - sweepAngle;
        dAngle = atan2(sin(dAngle), cos(dAngle));

        // Angular Gaussian for the arc segment — sharper / more
        // localized than the previous comet (sigma 0.09 rad ~= 5°)
        // so the glisten reads as a defined "trim" segment rather
        // than a wide bead.
        float arcSigma = 0.09;
        float arcMask = exp(-(dAngle * dAngle) / (2.0 * arcSigma * arcSigma));

        // Per-cycle opacity envelope: 0 -> 1 over the first 25% of
        // the cycle, hold at 1 from 25% -> 75%, 1 -> 0 over the last
        // 25%. The smoothstep edges round the seams so the loop
        // wraps without a visible flash when phase resets from 1 to 0.
        float envOpacity = smoothstep(0.0, 0.25, cyclePhase)
                         - smoothstep(0.75, 1.0, cyclePhase);

        // Radial mask: a narrow crest centered on the spine, feathered
        // across ~10% of the band's half-width. `focusedLineCore` —
        // which the static spine uses — is a 0.018–0.038 hairline
        // that renders sub-pixel at typical band widths, so any peak
        // brightness was averaged down across the rendered pixel and
        // the crest never actually reached white. This widened mask
        // gives the sweep a visible pixel footprint while staying
        // much thinner than the band body so it still reads as a
        // line-tracing trim rather than a wide bead.
        float trimRadial = 1.0 - smoothstep(0.0, 0.10, abs(bandT));
        trimSweep = arcMask * envOpacity * trimRadial;
    }

    float3 ringTone = in.color.rgb;
    ringTone = mix(ringTone, float3(1.0), focusedRing * 0.10);
    float innerRadiance = 0.0;
    if (focusedRing > 0.5) {
        float innerSide = saturate((1.0 - bandT) * 0.5);
        innerRadiance = pow(innerSide, 2.1) * (0.38 + focusedLineCore * 0.18);
    }
    float3 accountLight = clamp(in.signal.rgb * 1.55 + float3(0.035), 0.0, 1.0);
    ringTone = mix(ringTone, max(ringTone, accountLight), innerRadiance);
    ringTone = clamp(ringTone + accountLight * innerRadiance * 0.30, 0.0, 1.0);
    ringTone = mix(ringTone, float3(1.0), focusedRing * focusedLineCore * 0.36);
    // Apply orbital-light hemisphere dimming BEFORE the trim sweep so
    // the sweep crest isn't multiplied down by the same gradient that
    // dims the underlying band. Without this ordering, the white sweep
    // on the dim half (orbitalLight = 0.62) was scaled back to 0.62
    // grey — visually indistinguishable from the dimmed ring tone on
    // every tier except the one whose phase happened to keep the
    // sweep in the bright hemisphere when the user looked. Now the
    // sweep stays at pure white regardless of orbital-light side.
    if (focusedRing > 0.5) {
        float2 radialDir = in.uv / max(r, 0.0001);
        float orbitalLight = 0.62 + 0.38 * smoothstep(-0.30, 1.0, dot(radialDir, normalize(float2(0.42, 0.72))));
        ringTone *= orbitalLight;
    }
    // Trim-sweep glisten paints the arc segment as a bright-white
    // crest on the focused spine. The mix weight is saturated with a
    // 1.4x multiplier so the arc's central core reaches pure white
    // (mix weight 1.0) rather than capping at 95% white blended with
    // 5% ring tone — the previous cap let bright tier tones bleed
    // through the crest and washed out the contrast. The Gaussian
    // arc falloff still preserves the narrow visible footprint.
    ringTone = mix(ringTone, float3(1.0), saturate(trimSweep * 1.4));

    // Lower base alpha (was 0.82) so the body of each band is openly
    // translucent — the void reads through the ring the way it does
    // on a real planetary ring photo. The focused state lifts opacity
    // uniformly along the hard center spine via `focusedLineAlpha`,
    // and the trim-sweep arc adds a localized opacity crest where the
    // glisten currently sits.
    float alphaScale = mix(0.62, 1.08, focusedRing);
    float baseAlpha = in.color.a * (envelope + innerRadiance * 0.24) * alphaScale * dim;
    float focusedLineAlpha = focusedRing * focusedLineCore * (0.94 + trimSweep * 0.06);
    float alpha = max(baseAlpha, focusedLineAlpha);
    float deletion = saturate(in.lock.z);
    if (deletion > 0.0) {
        float darken = smoothstep(0.18, 0.78, deletion);
        ringTone = mix(ringTone, ringTone * 0.22, darken);
        alpha *= 1.0 - smoothstep(0.66, 1.0, deletion);
    }
    // Saturn-detail LOD: bands dissolve as their planet's apparent size
    // drops below legibility (the wide solar view shows clean orbs; the
    // rings resolve on approach).
    alpha *= saturate(in.lock.w);
    return float4(ringTone * dim, saturate(alpha));
}

// ---------------------------------------------------------------------------
// Person hub PLANET pipeline — 3D icosphere instanced per hub. Vertex shader
// scales a unit sphere by the hub radius and translates by its world center;
// fragment shader does diffuse + rim shading in world space so each planet
// shows a lit hemisphere relative to a fixed virtual sun direction. Pipeline
// participates in depth (writes depth) so Saturn-style ring occlusion works.
// ---------------------------------------------------------------------------

vertex PlanetOut constellation_person_planet_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device float3* sphereVerts [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    const device PersonPlanetInstance* planets [[buffer(2)]],
    const device float4* hubDisplacements [[buffer(3)]]
) {
    PersonPlanetInstance planet = planets[iid];
    // People solar system: the body rides its orbital displacement. Lane 0
    // (the sun, pinned/locked hubs, meaning clusters) is the identity.
    int hubLane = int(planet.orbital.x + 0.5);
    float4 hubEntry = hubDisplacements[max(0, hubLane)];
    float3 center = planet.centerRadius.xyz + (hubLane > 0 ? hubEntry.xyz : float3(0.0));
    float radius = max(planet.centerRadius.w, 0.0001);
    float3 spherePos = sphereVerts[vid];
    float3 worldPos = center + spherePos * radius;

    PlanetOut out;
    out.position = uniforms.viewProjection * float4(worldPos, 1.0);
    out.worldPos = worldPos;
    // Unit-sphere position IS the surface normal in object space; since the
    // per-instance transform is uniform-scale + translate, no rotation, the
    // world-space normal equals the object-space normal.
    out.worldNormal = normalize(spherePos);
    out.color = planet.color;
    out.glyphUV = planet.glyphUV;
    out.signal = planet.signal;
    out.orbital = planet.orbital;
    return out;
}

// Forward declaration — the iridescence fragment calls
// `mockup_hsv_to_rgb` (defined further down with the sandbox helpers)
// for the pearlescent rim, and Metal requires declarations before use.
static inline float3 mockup_hsv_to_rgb(float h, float s, float v);

fragment float4 constellation_person_planet_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float facing = clamp(dot(N, V), 0.0, 1.0);

    // The People solar system's sun — an emissive, limb-darkened radiant
    // body in whatever accent the CPU baked into in.color (the dynamic
    // sun accent; stamen register only as the exhausted-palette fallback).
    // Checked before the Meaning-cluster branch because its material
    // selector (signal.w = 3) sits above the cluster selectors. Structure,
    // not agency: the only motion is a slow positional granulation drift
    // matching the corona's currents.
    if (in.signal.w > 2.5) {
        float limb = 0.62 + 0.38 * pow(facing, 0.65);
        float3 body = in.color.rgb * limb;
        float centerHot = smoothstep(0.55, 1.0, facing);
        float3 hotTone = clamp(in.color.rgb * 1.35 + float3(0.10, 0.08, 0.02), 0.0, 1.0);
        body = mix(body, hotTone, centerHot * 0.55);
        float t = uniforms.viewportTimeScale.z;
        float grain = 0.965 + 0.035 * sin(dot(in.worldPos.xy, float2(41.7, 33.3)) + t * 0.35);
        // The sun participates in lock dims like every other body so a
        // locked portrait recedes it with the rest of the field.
        float fieldDim = saturate(uniforms.lockControls.x);
        float sunDim = fieldDim + (1.0 - fieldDim) * 0.25;
        return float4(body * grain * sunDim, 1.0);
    }

    // Iridescence — promoted to production from the design sandbox's
    // `mockup_planet_iridescence_fragment`. The orb reads as a Lambert-
    // shaded body in the AccountColor with a pearlescent rim that
    // shifts hue ~42% across the silhouette as the surface curves
    // away (soap-bubble / thin-film look). The base hue is derived
    // from the per-hub AccountColor so every correspondent keeps its
    // chromatic identity at the orb's centre; the rim is a hue-rotated
    // shade of the same chroma family so the iridescence reads as a
    // material property rather than an unrelated colour wash.
    //
    // Time-independent: the body has no animated term, so the orb is
    // static between camera moves. The People-lens view's redraw
    // contract is driven by the locked-correspondent ring trim-sweep;
    // Meaning cluster nuclei are also static so they do not hold a
    // settled lens at 60fps. Unlocked galaxy views and live locked
    // portraits both route through this fragment, so both inherit
    // the look in lockstep.
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float NdotL = max(0.0, dot(N, L));
    // Base lit body — keep the hub's AccountColor legible at the
    // centre of the orb. The pearlescent treatment below can add rim
    // colour, but it must not collapse different accounts back into
    // the same cyan/blue material.
    float accountLuma = dot(in.color.rgb, float3(0.30, 0.59, 0.11));
    float3 accountAlbedo = clamp(
        float3(accountLuma) + (in.color.rgb - float3(accountLuma)) * 1.65,
        0.0,
        1.0
    );
    float3 lit = accountAlbedo * (0.58 + NdotL * 0.32);

    // Cheap RGB→H conversion to seed the rim hue rotation. We don't
    // need full HSV for the body; the rim is the only term that
    // operates in hue space.
    float cMax = max(max(in.color.r, in.color.g), in.color.b);
    float cMin = min(min(in.color.r, in.color.g), in.color.b);
    float delta = max(cMax - cMin, 0.0001);
    float baseHue;
    if (cMax == in.color.r) {
        baseHue = fmod(((in.color.g - in.color.b) / delta), 6.0) / 6.0;
    } else if (cMax == in.color.g) {
        baseHue = (((in.color.b - in.color.r) / delta) + 2.0) / 6.0;
    } else {
        baseHue = (((in.color.r - in.color.g) / delta) + 4.0) / 6.0;
    }
    baseHue = fract(baseHue + 1.0);

    // Rim parameter — facing 0 = silhouette, facing 1 = facing the
    // camera. The smoothstep gates the iridescent contribution to
    // the outer ~60% of the projected disc so the centre stays
    // unambiguously the AccountColor.
    float rimT = smoothstep(0.05, 0.65, 1.0 - facing);
    // Hue rotates by 0.42 of the wheel from base across the rim, so
    // every account hue gets its own characteristic rim spectrum
    // (cyan accounts shift cyan→teal→violet at the rim, red accounts
    // shift red→amber→cyan, etc).
    float irisHue = fract(baseHue + 0.42 * rimT);
    float irisSat = 0.55 + 0.20 * rimT;
    float irisVal = 0.85 + 0.15 * rimT;
    float3 irisTone = mockup_hsv_to_rgb(irisHue, irisSat, irisVal);
    float rim = pow(1.0 - facing, 2.8);
    float3 irisContrib = irisTone * rim * 0.12;

    // Subtle specular pearl in the iridescent hue (not white) so the
    // reflective highlight reads as part of the thin-film material
    // rather than a generic glossy spec.
    float3 H = normalize(L + V);
    float spec = pow(max(0.0, dot(N, H)), 24.0);
    float3 accountSpec = mix(irisTone, accountAlbedo, 0.72);
    float3 surface = lit + irisContrib + accountSpec * spec * 0.10;
    float centerTint = smoothstep(0.36, 0.96, facing);
    float3 centerAccount = accountAlbedo * (0.92 + NdotL * 0.08);
    surface = mix(surface, centerAccount, centerTint * 0.78);
    // `focusGlow` is read further down to lift the recency-dim
    // brightness to full when the user has locked this correspondent
    // (the locked hub shouldn't read as "dormant" while focused).
    // No additive halo on the orb itself — focal emphasis comes from
    // the ring shimmer pulse and the close camera framing.
    float focusGlow = clamp(in.signal.y, 0.0, 1.0);
    float peopleDeletion = saturate(-in.signal.w);

    // Meaning-lens cluster marker. Distinguished from People hub planets
    // by `signal.w`:
    //   1 = broad transparent semantic field
    //   2 = dense centre nucleus / hover target
    //
    // The CPU emits both instances per cluster. That keeps the cluster's
    // large transparent reach independent from the small, definite point
    // the user can hover. Meaning clusters use their own Lambert-based
    // body shading and palette-chroma-boost composite, so the outer
    // iridescence surface above is replaced wholesale inside this
    // branch. `NdotL` and `L` from the iridescence path are reused
    // here (same world-fixed sun direction every pipeline shares).
    bool isMeaningCluster = in.signal.w > 0.5;
    if (isMeaningCluster) {
        // Lock-transition fade: `lockControls.y` ramps 1 → 0 as a node
        // lock engages (and back on exit), so cluster bodies dissolve
        // with the field dim instead of popping at a packet boundary.
        // Fully-faded fragments (settled locked scene) discard outright.
        float clusterVisibility = saturate(uniforms.lockControls.y);
        if (clusterVisibility <= 0.001) {
            discard_fragment();
        }
        float density = clamp(in.signal.x, 0.0, 1.0);
        float phase = in.signal.z;
        bool isCore = in.signal.w > 1.5;

        // Boost chroma so the muted MeaningClusterPalette hue survives the
        // alpha-blend against the dark void. The palette ships at ~0.55
        // saturation — without this boost the categorical identity reads
        // as cream/white at low alphas. ~50% boost lands the perceived
        // chroma close to the SwiftUI sandbox while preserving the
        // palette's mid-luminance read.
        float lum = dot(in.color.rgb, float3(0.30, 0.59, 0.11));
        float3 albedo = clamp(float3(lum) + (in.color.rgb - float3(lum)) * 1.50,
                              0.0, 1.0);

        if (!isCore) {
            // Translucent semantic field. The radial alpha is gated by
            // `smoothstep(0.20, 1.0, facing)` rather than raw `facing`, so
            // alpha is fully zero across the outer 20% of the projected
            // disk. That pushes the icosphere's polygon silhouette into a
            // zero-alpha feather zone — the visible "edge" is the soft
            // alpha falloff well inside the geometry, never the polygon
            // boundary. Result: no hard rim, no faceted silhouette, just
            // a smooth dissolve into the void.
            float feathered = smoothstep(0.20, 1.0, facing);
            float radial = pow(feathered, 1.8);
            float3 body = albedo * (0.55 + NdotL * 0.30);
            // Inward bloom stays in the cluster's hue family rather than
            // shifting toward white — the centre reads as "denser hue,"
            // not as a luminous white core leaking outward through the
            // surrounding shell.
            float coreBloom = smoothstep(0.55, 1.0, facing) * (0.12 + density * 0.08);
            body += albedo * coreBloom;
            // Lower cap (was 0.18 + 0.22*density) so orbs read as ambient
            // density fields rather than dominant bodies. Density still
            // separates intense from quiet across a perceptible range.
            float alpha = radial * (0.12 + density * 0.16);
            return float4(body, saturate(alpha) * clusterVisibility);
        }

        // Defined centre nucleus — three concentric layers in the cluster's
        // own hue, so the cluster always has one clear, defined hover anchor
        // without a broad white-out that erases the categorical colour:
        //   outer shell  : hue-shaded body (cluster's identity colour)
        //   mid glow     : hue-bright zone (saturated cluster colour)
        //   apex point   : tight, brightest hue band at the very centre
        float nucleusLift = 0.94 + 0.06 * sin(phase);
        // Transient hover flare: the hovered cluster's phase + 1 rides
        // `lockControls.w` (see `setHoveredMeaningCluster`). The nucleus
        // brightens and widens its white apex while hovered — the anchor
        // answering the pointer before the hover card mounts. The spike
        // halo sprite flares on the same match.
        float nucleusHoverLane = uniforms.lockControls.w;
        float nucleusHovered =
            (nucleusHoverLane > 0.5 && abs(nucleusHoverLane - 1.0 - phase) < 0.00005) ? 1.0 : 0.0;
        nucleusLift *= 1.0 + 0.30 * nucleusHovered;
        // Outer-band feathering so the core's polygon edge dissolves too.
        float coreFeather = smoothstep(0.08, 1.0, facing);
        // Mid glow extent — a wider zone where the cluster colour intensifies.
        float coreGlow = pow(coreFeather, 2.4);
        // Apex point — a *very* tight near-white pinpoint at the exact
        // centre of the projected disk. Smoothstep(0.985, 1.0) means the
        // white only blooms where the disk-radius ratio r < ~17%, with
        // most of the brightness concentrated in the inner 10%. That
        // gives the orb a small, unambiguous "I am right here" hover
        // anchor without bleeding outward and washing out the hue. The
        // hover flare widens it slightly.
        float apex = smoothstep(0.985 - 0.015 * nucleusHovered, 1.0, facing);

        float3 hueShell = albedo * (0.55 + NdotL * 0.30);
        float3 hueBright = clamp(albedo * 1.50, 0.0, 1.0);
        // Defined white centre. Crisp white pinpoint, no hue tinting —
        // the centre reads as a true centre against the surrounding
        // hue-bright glow.
        float3 whitePoint = float3(0.98, 0.98, 1.0);

        // Layered composition: shell → hue-bright glow → tight white tip.
        float3 finalColor = mix(hueShell, hueBright, coreGlow);
        finalColor = mix(finalColor, whitePoint, apex * nucleusLift);

        // Alpha. Front feather defines the body's fall-off; the apex
        // contributes its own alpha so the centre point reads as fully
        // present on the brightest fragment regardless of cluster density.
        float front = smoothstep(0.0, 0.55, facing);
        float alpha = front * (0.82 + density * 0.18) * nucleusLift * coreFeather;
        alpha = max(alpha, apex * nucleusLift);
        return float4(finalColor, saturate(alpha) * clusterVisibility);
    }

    if (in.glyphUV.z > 0.0 && in.glyphUV.w > 0.0) {
        float3 R = normalize(uniforms.cameraRight.xyz);
        float3 U = normalize(uniforms.cameraUp.xyz);
        // Project the visible hemisphere into the camera-facing disk.
        // This makes the printed name/initials/icon face the reset/startup
        // camera directly, while still being shaded as part of the sphere.
        // `signal.z` widens the patch for two-line full names baked in the
        // glyph atlas (see `PersonOrbLabel` in ConstellationMetalRenderer).
        float wideDecal = in.signal.z > 0.5 ? 1.0 : 0.0;
        float patchScale = wideDecal > 0.5 ? 1.22 : 0.90;
        float2 local = float2(
            0.5 + dot(N, R) * patchScale,
            0.5 - dot(N, U) * patchScale
        );
        if (all(local >= float2(0.0)) && all(local <= float2(1.0))) {
            float2 atlasUV = in.glyphUV.xy + local * in.glyphUV.zw;
            // The atlas is now a signed distance field (see
            // `SignedDistanceField` / `PersonOrbLabel.sdfTile`), not a raw
            // alpha mask: 0.5 marks the glyph boundary, values above/below
            // encode distance to it. That keeps the label crisp at any
            // on-screen scale — a fixed-resolution raster either blurs
            // under magnification (locked close-up focus) or aliases under
            // minification (small background hubs), which a smooth,
            // properly mip-mapped distance field does not.
            float sdf = glyphTexture.sample(glyphSampler, atlasUV).r;
            float radial = length(local - float2(0.5));
            float frontFade = smoothstep(0.04, 0.30, facing);
            float radialLimit = wideDecal > 0.5 ? 0.48 : 0.46;
            float decalFade = 1.0 - smoothstep(radialLimit, 0.50, radial);
            float coverage = frontFade * decalFade;

            // Screen-space derivative of the field gives an
            // analytically-correct antialiasing width, so the edge stays
            // exactly one pixel wide whether the orb fills 8px or 800px —
            // the same reason this reads sharp instead of soft at any zoom.
            float aa = max(fwidth(sdf), 1.0 / 256.0);
            float fillEdge = 0.5;
            float strokeEdge = fillEdge - 0.16;
            float fillMask = smoothstep(fillEdge - aa, fillEdge + aa, sdf) * coverage;
            float outerMask = smoothstep(strokeEdge - aa, strokeEdge + aa, sdf) * coverage;
            float strokeMask = saturate(outerMask - fillMask);

            float useDarkLabel = smoothstep(0.70, 0.80, accountLuma);
            float3 outlineInk = mix(
                float3(0.015, 0.017, 0.022),
                float3(0.94, 0.93, 0.86),
                useDarkLabel
            );
            surface = mix(surface, outlineInk, saturate(strokeMask * 0.62));
            float3 ink = mix(
                float3(0.96, 0.96, 0.92),
                float3(0.020, 0.021, 0.024),
                useDarkLabel
            );
            surface = mix(surface, ink, saturate(fillMask * 0.88));
        }
    }

    // Recency dim — the lit + rim shading reads as a sphere from any
    // brightness, so dimming the final composited color leaves the geometry
    // intact while making dormant correspondents read as visibly quiet.
    // Map recency [0,1] to brightness [0.55, 1.0] so even fully-dormant
    // hubs remain recognizable bodies, not vanished holes.
    float recency = clamp(in.signal.x, 0.0, 1.0);
    float brightness = 0.55 + 0.45 * recency;
    brightness = mix(brightness, 1.0, focusGlow);
    surface *= brightness;

    // Context dim — `color.a` carries a [0,1] brightness multiplier. In the
    // People focus portrait the unfocused background correspondent hubs are
    // tagged below 1.0 so they recede into a faint backdrop behind the
    // focused Saturn (the People analogue of the Meanings field dim), while
    // the focused hub and any ring-bearing hubs stay at 1.0. Meaning-lens
    // clusters return earlier (above), so this multiply is People-hub-only;
    // every other planet path encodes `color.a == 1.0` and is unaffected.
    float peopleContextDimPhase = saturate(uniforms.lockControls.z);
    float contextDim = mix(1.0, clamp(in.color.a, 0.0, 1.0), peopleContextDimPhase);
    surface *= contextDim;

    // Petal-red ember rim — the static correlate of open-obligation
    // urgency, so "owes my attention" stays readable while the orbital
    // motion is stopped. Applied after the recency/context dims so the
    // ember reads at constant strength on bright and receded bodies
    // alike; intensity is the same age-weighted score that drives the
    // planet's orbital speed. This is the design system's sanctioned
    // petal-red state-of-message register.
    float ember = saturate(in.orbital.y);
    if (ember > 0.001) {
        float emberRim = pow(1.0 - facing, 2.4);
        float3 emberTone = float3(0.910, 0.220, 0.220);
        surface = clamp(surface + emberTone * emberRim * ember * (0.55 + 0.45 * contextDim), 0.0, 1.0);
    }
    if (peopleDeletion > 0.0) {
        // Final-correspondent collapse. Geometry shrinks CPU-side so the
        // planet is visibly pulled inward; this material pass dims the
        // remaining surface into the same event-horizon darkness used by
        // message-node deaths without changing the Meaning-cluster branch
        // that also shares this shader.
        float darken = smoothstep(0.10, 0.76, peopleDeletion);
        surface = mix(surface, surface * 0.10, darken);
    }
    return float4(surface, 1.0);
}

// ---------------------------------------------------------------------------
// Person orbit-path pass — the People solar system's engraved chart layer.
// Each instance is one conic traced as a 192-vertex line strip: whisper-
// alpha orbit ellipses (sun at the focus), dashed near-parabolic comet
// arcs, and the faint concentric recency band guides. Paths are time-
// invariant — the body moves along its ellipse; the ellipse itself never
// displaces — so this pass reads no displacement table.
// ---------------------------------------------------------------------------

vertex OrbitPathOut constellation_person_orbit_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device PersonOrbitPathInstance* orbits [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    PersonOrbitPathInstance orbit = orbits[iid];
    float t = float(vid) / 191.0;
    float nu = t * 6.2831853;
    float e = clamp(orbit.axisPE.w, 0.0, 0.97);
    float p = orbit.centerPeri.w * (1.0 + e);      // semi-latus rectum
    float r = p / max(0.05, 1.0 + e * cos(nu));
    float3 world = orbit.centerPeri.xyz
        + orbit.axisPE.xyz * (cos(nu) * r)
        + orbit.axisQH.xyz * (sin(nu) * r);

    OrbitPathOut out;
    out.position = uniforms.viewProjection * float4(world, 1.0);
    out.color = orbit.colorAlpha;
    out.styleKind = orbit.style.x;
    // Transient hover (uniform lane) or the locked correspondent's baked
    // focus both brighten this hub's engraved path.
    float hovered = (uniforms.lockControls.w > 0.5
        && abs(uniforms.lockControls.w - orbit.axisQH.w) < 0.5) ? 1.0 : 0.0;
    out.highlight = max(orbit.style.y, hovered);
    out.pathT = t;
    return out;
}

fragment float4 constellation_person_orbit_fragment(
    OrbitPathOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]]
) {
    // Comet arcs render dashed — the broadcast class stays visually
    // distinct from one-sided human ellipses even where the aphelion cap
    // compresses their eccentricities together.
    if (in.styleKind > 1.5) {
        if (fract(in.pathT * 46.0) > 0.62) {
            discard_fragment();
        }
    }
    // Paths recede with the locked field dim like every ambient layer.
    float dim = lock_dim_multiplier(0.0, uniforms);
    float alpha = in.color.a * mix(1.0, 3.4, saturate(in.highlight)) * dim;
    float3 color = mix(in.color.rgb, float3(1.0), saturate(in.highlight) * 0.22);
    return float4(color * dim, saturate(alpha));
}

// ---------------------------------------------------------------------------
// Mockup planet fragments — debug design studies only
// ---------------------------------------------------------------------------
//
// Ten experimental treatments of the People-lens central orb (six material
// studies plus four reference-inspired looks),
// each sharing `constellation_person_planet_vertex` and re-using the same
// PersonPlanetInstance layout + glyph atlas mechanism. None of these are
// wired into the production People lens; they remain as shader reference so
// alternate visual treatments can be compared against the production
// fragment (`constellation_person_planet_fragment`).
//
// Conventions across all six:
//   * Glyph atlas decal composites identically to the production
//     fragment so the contact's initials read the same in every variant.
//     Decal pixels are face-aligned via the camera's right/up vectors.
//   * Sun direction matches production (`L = (0.42, 0.72, 0.55)`) so
//     comparisons are about material, not lighting setup.
//   * No recency dim, no focus glow signal modulation — the sandbox
//     drives `signal` to fixed (1.0, 0.0, 0.0, 0.0) so each variant
//     renders at full brightness without conflating recency state.

// Shared decal compositor — same math as the production fragment, lifted
// into a helper so every variant uses the same atlas sampling rules.
static inline float3 mockup_apply_glyph_decal(
    float3 surface,
    float3 N,
    float facing,
    float3 cameraPos,
    float3 worldPos,
    float4 glyphUV,
    texture2d<float> glyphTexture,
    sampler glyphSampler,
    float wideDecal
) {
    if (glyphUV.z <= 0.0 || glyphUV.w <= 0.0) {
        return surface;
    }
    float3 V = normalize(cameraPos - worldPos);
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 R = normalize(cross(worldUp, V));
    if (length(R) < 0.001) { R = float3(1.0, 0.0, 0.0); }
    float3 U = normalize(cross(V, R));
    float patchScale = wideDecal > 0.5 ? 1.22 : 0.90;
    float2 local = float2(
        0.5 + dot(N, R) * patchScale,
        0.5 - dot(N, U) * patchScale
    );
    if (any(local < float2(0.0)) || any(local > float2(1.0))) {
        return surface;
    }
    float2 atlasUV = glyphUV.xy + local * glyphUV.zw;
    float4 glyph = glyphTexture.sample(glyphSampler, atlasUV);
    float radial = length(local - float2(0.5));
    float frontFade = smoothstep(0.04, 0.30, facing);
    float radialLimit = wideDecal > 0.5 ? 0.48 : 0.46;
    float decalFade = 1.0 - smoothstep(radialLimit, 0.50, radial);
    float glyphLuma = max(max(glyph.r, glyph.g), glyph.b) / max(glyph.a, 0.001);
    float fillMask = glyph.a * smoothstep(0.42, 0.90, glyphLuma) * frontFade * decalFade;
    float strokeMask = glyph.a * (1.0 - smoothstep(0.18, 0.58, glyphLuma)) * frontFade * decalFade;
    float3 outlineInk = float3(0.015, 0.017, 0.022);
    float3 result = mix(surface, outlineInk, saturate(strokeMask * 0.62));
    float3 ink = float3(0.94, 0.97, 1.0);
    return mix(result, ink, saturate(fillMask * 0.88));
}

// Mockup-sandbox sharp path — retina atlas + tighter masks. Selected when
// `uniforms.lockControls.x > 0.5` (see `mockup_apply_glyph_decal_sandbox`).
static inline float3 mockup_apply_glyph_decal_sharp(
    float3 surface,
    float3 N,
    float facing,
    float3 cameraPos,
    float3 worldPos,
    float4 glyphUV,
    texture2d<float> glyphTexture,
    sampler glyphSampler,
    float wideDecal
) {
    if (glyphUV.z <= 0.0 || glyphUV.w <= 0.0) {
        return surface;
    }
    float3 V = normalize(cameraPos - worldPos);
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 R = normalize(cross(worldUp, V));
    if (length(R) < 0.001) { R = float3(1.0, 0.0, 0.0); }
    float3 U = normalize(cross(V, R));
    float patchScale = wideDecal > 0.5 ? 1.22 : 0.90;
    float2 local = float2(
        0.5 + dot(N, R) * patchScale,
        0.5 - dot(N, U) * patchScale
    );
    if (any(local < float2(0.0)) || any(local > float2(1.0))) {
        return surface;
    }
    float2 atlasUV = glyphUV.xy + local * glyphUV.zw;
    float4 glyph = glyphTexture.sample(glyphSampler, atlasUV);
    float radial = length(local - float2(0.5));
    float frontFade = smoothstep(0.03, 0.22, facing);
    float radialLimit = wideDecal > 0.5 ? 0.48 : 0.47;
    float decalFade = 1.0 - smoothstep(radialLimit, 0.50, radial);
    float coverage = glyph.a * frontFade * decalFade;
    float glyphLuma = max(max(glyph.r, glyph.g), glyph.b) / max(glyph.a, 0.001);
    float outline = coverage * (1.0 - smoothstep(0.38, 0.58, glyphLuma));
    float fill = coverage * smoothstep(0.50, 0.72, glyphLuma);
    float3 outlineInk = float3(0.02, 0.025, 0.032);
    float3 ink = float3(0.97, 0.99, 1.0);
    float3 result = mix(surface, outlineInk, saturate(outline * 0.50));
    return mix(result, ink, saturate(fill * 0.96));
}

// Routes to legacy (production-style) or sharp decal compositing.
static inline float3 mockup_apply_glyph_decal_sandbox(
    float3 surface,
    float3 N,
    float facing,
    constant CameraUniforms& uniforms,
    float3 worldPos,
    float4 glyphUV,
    texture2d<float> glyphTexture,
    sampler glyphSampler
) {
    float wideDecal = uniforms.lockControls.y;
    if (uniforms.lockControls.x > 0.5) {
        return mockup_apply_glyph_decal_sharp(
            surface, N, facing, uniforms.cameraPositionAndTier.xyz, worldPos,
            glyphUV, glyphTexture, glyphSampler, wideDecal
        );
    }
    return mockup_apply_glyph_decal(
        surface, N, facing, uniforms.cameraPositionAndTier.xyz, worldPos,
        glyphUV, glyphTexture, glyphSampler, wideDecal
    );
}

// Tiny stable hash → unit-range float for procedural noise.
static inline float mockup_hash13(float3 p) {
    p = fract(p * float3(443.8975, 397.2973, 491.1871));
    p += dot(p, p.yxz + 19.19);
    return fract((p.x + p.y) * p.z);
}

// Cheap value noise on a unit-sphere normal. Good enough for the sandbox
// — not used for production, not perceptually tiled, but stable and
// continuous across frame draws.
static inline float mockup_value_noise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = mockup_hash13(i + float3(0,0,0));
    float n100 = mockup_hash13(i + float3(1,0,0));
    float n010 = mockup_hash13(i + float3(0,1,0));
    float n110 = mockup_hash13(i + float3(1,1,0));
    float n001 = mockup_hash13(i + float3(0,0,1));
    float n101 = mockup_hash13(i + float3(1,0,1));
    float n011 = mockup_hash13(i + float3(0,1,1));
    float n111 = mockup_hash13(i + float3(1,1,1));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

// HSV -> RGB helper for the iridescence variant.
static inline float3 mockup_hsv_to_rgb(float h, float s, float v) {
    float3 k = float3(1.0, 2.0 / 3.0, 1.0 / 3.0);
    float3 p = abs(fract(float3(h) + k) * 6.0 - float3(3.0));
    return v * mix(float3(1.0), clamp(p - float3(1.0), 0.0, 1.0), s);
}

// Variant 1 — Lighting: brighter lit hemisphere, sharp specular,
// saturated rim. Tuned in two stages from production:
//
//   1. Lighting baseline reversed the "flatten" tuning of
//      `constellation_person_planet_fragment` (ambient 0.30→0.10,
//      diffuse 0.55→0.88, spec 0.06→0.24, rim 0.10→0.30).
//   2. Brightness + saturation pass on top of that baseline: ambient
//      and diffuse both raised so the dark hemisphere keeps a
//      recognizable base hue while the lit side reads as vividly
//      coloured; spec/rim multipliers raised and their tints pulled
//      MORE chromatic (less white admixture) so the highlights
//      preserve the AccountColor's identity instead of washing
//      toward grey; base albedo gets a +15% chroma boost before any
//      light term touches it so the entire orb reads as a more
//      saturated body even where Lambert mixes the colour toward
//      black on the dark side.
//
// The bloom containment math is omitted here (no ring context in the
// sandbox) — the production fragment retains its bloom + containment
// so the ring gap stays unambiguous in the live People lens.
fragment float4 mockup_planet_lighting_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float3 H = normalize(L + V);
    // +15% chroma boost on the base albedo so the AccountColor reads
    // more vividly through every lighting term. Luminance-preserving:
    // pushes the colour away from its grey-line projection without
    // shifting overall brightness, keeping the orb the same value at
    // the lit pole while reading distinctly more saturated.
    float3 baseAlbedo = in.color.rgb;
    float lum = dot(baseAlbedo, float3(0.299, 0.587, 0.114));
    baseAlbedo = clamp(float3(lum) + (baseAlbedo - float3(lum)) * 1.15, 0.0, 1.0);

    float NdotL = max(0.0, dot(N, L));
    float ambient = 0.20;
    float3 lit = baseAlbedo * (ambient + NdotL * 1.00);
    float spec = pow(max(0.0, dot(N, H)), 30.0);
    // Specular tint: more colored, less white. `baseAlbedo * 1.25 + 0.04`
    // preserves the AccountColor hue at the highlight crest instead of
    // washing toward neutral white.
    float3 highlight = (baseAlbedo * 1.25 + float3(0.03, 0.03, 0.05)) * spec * 0.32;
    float facing = clamp(dot(N, V), 0.0, 1.0);
    float rim = pow(1.0 - facing, 5.0);
    float3 rimColor = baseAlbedo * 1.10 + float3(0.05, 0.05, 0.07);
    float3 rimContrib = rimColor * rim * 0.34;
    float3 surface = lit + highlight + rimContrib;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 2 — Atmosphere: a wide atmospheric scattering halo at the
// silhouette. Same diffuse base as production but the rim becomes a
// broad cool-tinted glow that reaches into the sphere's outer band,
// giving the orb a Mars/Earth atmosphere look without altering the
// disk's silhouette geometry.
fragment float4 mockup_planet_atmosphere_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(N, L));
    float3 lit = in.color.rgb * (0.22 + NdotL * 0.65);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    // Atmospheric scattering: peak at the silhouette (facing ~ 0),
    // broadens inward via a soft smoothstep, falls off at the center.
    float scattering = pow(1.0 - facing, 2.2) * smoothstep(0.0, 0.6, NdotL);
    // Slightly cooler atmosphere tint — pull the hue toward blue/white
    // so the halo reads as scattered light rather than the surface
    // colour bleeding outward.
    float3 atmosphereTint = mix(in.color.rgb, float3(0.85, 0.92, 1.05), 0.55);
    float3 atmosphere = atmosphereTint * scattering * 0.85;
    // Day-side haze — a subtle uniform brightening on the lit hemisphere.
    float dayHaze = smoothstep(0.0, 0.4, NdotL) * 0.10;
    float3 surface = lit + atmosphere + atmosphereTint * dayHaze;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 3 — Bands: procedural Jupiter-style horizontal banding.
// Sinusoidal modulation along the planet's local Y axis tints stripes
// of the surface lighter and darker than the base albedo. The bands
// rotate with the sphere normal so a hub at any orientation shows
// belts/zones aligned to its local equator.
fragment float4 mockup_planet_bands_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(N, L));
    // 8 stripes from pole to pole, with a soft fbm modulation so adjacent
    // bands don't read as a perfect sine grid.
    float latitude = N.y;
    float bandSignal = sin(latitude * 9.0) * 0.5 + 0.5;
    float bandNoise = mockup_value_noise(N * 4.0);
    float bandMix = mix(bandSignal, bandNoise, 0.18);
    // Bands modulate albedo between a darker (warm) and lighter (cool)
    // version of the base colour, so the hue stays the AccountColor's
    // identity but the eye reads horizontal banding.
    float3 darkBand = in.color.rgb * 0.70;
    float3 lightBand = mix(in.color.rgb, float3(1.0), 0.18);
    float3 banded = mix(darkBand, lightBand, bandMix);
    float3 lit = banded * (0.22 + NdotL * 0.72);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    float rim = pow(1.0 - facing, 4.8);
    float3 rimContrib = banded * 0.85 * rim * 0.18;
    float3 surface = lit + rimContrib;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 4 — Topography: procedural noise perturbs the surface normal
// before lighting so the orb reads as a rocky / terrain-bearing body.
// The base albedo stays the AccountColor; the noise modulates BOTH the
// normal (for Lambert variation) and a subtle multiplier on the albedo
// (so darker patches read as deeper craters / shadows).
fragment float4 mockup_planet_topography_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    // Sample noise at two scales for low-frequency continents + finer
    // craters. The gradient of the noise becomes a tangent-space bump.
    float epsilon = 0.04;
    float n0 = mockup_value_noise(N * 5.0)
             + mockup_value_noise(N * 13.0) * 0.45;
    float nX = mockup_value_noise((N + float3(epsilon, 0, 0)) * 5.0)
             + mockup_value_noise((N + float3(epsilon, 0, 0)) * 13.0) * 0.45;
    float nY = mockup_value_noise((N + float3(0, epsilon, 0)) * 5.0)
             + mockup_value_noise((N + float3(0, epsilon, 0)) * 13.0) * 0.45;
    float nZ = mockup_value_noise((N + float3(0, 0, epsilon)) * 5.0)
             + mockup_value_noise((N + float3(0, 0, epsilon)) * 13.0) * 0.45;
    float3 grad = float3(nX - n0, nY - n0, nZ - n0) / epsilon;
    // Perturb normal in the tangent plane, then re-orthogonalize.
    float3 perturbed = normalize(N - grad * 0.06);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(perturbed, L));
    // Albedo modulation — darker valleys (low noise), lighter peaks.
    float albedoShift = (n0 - 0.5) * 0.40;
    float3 albedo = clamp(in.color.rgb * (1.0 + albedoShift), 0.0, 1.0);
    float3 lit = albedo * (0.18 + NdotL * 0.78);
    float rim = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);
    float3 rimContrib = albedo * 0.80 * rim * 0.20;
    float3 H = normalize(L + V);
    float spec = pow(max(0.0, dot(perturbed, H)), 22.0) * 0.10;
    float3 surface = lit + rimContrib + float3(spec);
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, clamp(dot(N, V), 0.0, 1.0), uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 5 — Iridescence: pearlescent rim that shifts hue based on
// viewing angle. The visible center is the AccountColor; the rim
// gradient cycles through a thin-film-like spectrum (hue rotation in
// HSV) so the silhouette reads as iridescent / soap-bubble.
fragment float4 mockup_planet_iridescence_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(N, L));
    float3 lit = in.color.rgb * (0.20 + NdotL * 0.70);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    // Compute the base hue from the AccountColor (cheap RGB-> H approx).
    float cMax = max(max(in.color.r, in.color.g), in.color.b);
    float cMin = min(min(in.color.r, in.color.g), in.color.b);
    float delta = max(cMax - cMin, 0.0001);
    float baseHue;
    if (cMax == in.color.r) {
        baseHue = fmod(((in.color.g - in.color.b) / delta), 6.0) / 6.0;
    } else if (cMax == in.color.g) {
        baseHue = (((in.color.b - in.color.r) / delta) + 2.0) / 6.0;
    } else {
        baseHue = (((in.color.r - in.color.g) / delta) + 4.0) / 6.0;
    }
    baseHue = fract(baseHue + 1.0);
    // Hue cycles 0.5x of the wheel from base across the rim.
    float rimT = smoothstep(0.05, 0.65, 1.0 - facing);
    float irisHue = fract(baseHue + 0.42 * rimT);
    float irisSat = 0.55 + 0.20 * rimT;
    float irisVal = 0.85 + 0.15 * rimT;
    float3 irisTone = mockup_hsv_to_rgb(irisHue, irisSat, irisVal);
    float rim = pow(1.0 - facing, 2.8);
    float3 irisContrib = irisTone * rim * 0.55;
    // Subtle specular pearl in the iridescent hue.
    float3 H = normalize(L + V);
    float spec = pow(max(0.0, dot(N, H)), 24.0);
    float3 surface = lit + irisContrib + irisTone * spec * 0.30;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 6 — Emissive: bright inner bloom in the AccountColor hue so
// the orb reads as glowing from within. Production fragment also has
// an inner bloom but tuned to be subtle (0.55 contribution, contained
// to the central ~40% of the disc). This variant cranks the bloom up
// and extends its reach so the entire visible disc glows, with the
// rim treated as a softer halo rather than a hairline.
fragment float4 mockup_planet_emissive_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.42, 0.72, 0.55));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(N, L));
    // Lower diffuse weight so the emissive bloom dominates without
    // saturating; ambient lifted so the unlit hemisphere also glows.
    float3 lit = in.color.rgb * (0.32 + NdotL * 0.40);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    // Wide, bright inner bloom — extends well into the outer 40% of
    // the projected disc (was contained to the inner 40% in the
    // production fragment).
    float centerBloom = pow(facing, 1.6);
    float containment = smoothstep(0.05, 0.95, facing);
    float3 bloomTint = clamp(in.color.rgb * 1.20 + float3(0.05), 0.0, 1.0);
    float3 emission = bloomTint * centerBloom * containment * 1.10;
    // Soft outward rim halo — peaks just inside the silhouette.
    float rim = pow(1.0 - facing, 2.6);
    float3 rimContrib = bloomTint * rim * 0.32;
    float3 surface = lit + emission + rimContrib;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Spherical longitude / latitude in radians from a unit normal.
static inline float2 mockup_sphere_lon_lat(float3 N) {
    return float2(atan2(N.z, N.x), asin(clamp(N.y, -1.0, 1.0)));
}

// Distance to nearest meridian or parallel grid line (0 = on line).
static inline float mockup_wireframe_line_mask(float2 lonLat, float meridians, float parallels) {
    float lon01 = lonLat.x / (2.0 * M_PI_F) + 0.5;
    float lat01 = lonLat.y / (M_PI_F) + 0.5;
    float merid = abs(fract(lon01 * meridians) - 0.5) * 2.0;
    float par = abs(fract(lat01 * parallels) - 0.5) * 2.0;
    float meridLine = 1.0 - smoothstep(0.02, 0.055, merid);
    float parLine = 1.0 - smoothstep(0.02, 0.055, par);
    return saturate(max(meridLine, parLine));
}

// Variant 7 — Particle flow: additive neon filaments on a dark volumetric
// core, inspired by glowing particle-globe references (flowing strands,
// latitudinal dots, violet/blue/gold accents).
fragment float4 mockup_planet_particleFlow_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    float time = uniforms.viewportTimeScale.z;

    float2 lonLat = mockup_sphere_lon_lat(N);
    float lon = lonLat.x;
    float lat = lonLat.y;

    // Swirling streamlines — three phase-offset sine bundles.
    float flowA = sin(lon * 3.0 + lat * 5.0 + time * 0.85);
    float flowB = sin(lon * 5.0 - lat * 4.0 - time * 0.62 + 1.4);
    float flowC = cos(lat * 7.0 + time * 0.48);
    float strand = pow(abs(flowA * 0.55 + flowB * 0.35 + flowC * 0.25), 2.4);
    strand *= smoothstep(0.08, 0.92, facing);

    // Latitudinal dot chains (middle reference sphere).
    float dotBand = abs(sin(lat * 11.0 + time * 0.35));
    float dots = pow(1.0 - dotBand, 18.0) * smoothstep(0.12, 0.88, facing);

    float halo = pow(1.0 - facing, 2.2);
    float3 neonBlue = float3(0.18, 0.72, 1.05);
    float3 neonViolet = float3(0.62, 0.28, 1.05);
    float3 neonGold = float3(1.05, 0.62, 0.18);
    float3 baseTint = mix(in.color.rgb, float3(0.08, 0.12, 0.22), 0.72);

    float3 body = baseTint * (0.06 + facing * 0.14);
    float3 filaments = neonBlue * strand * 0.95
                     + neonViolet * strand * strand * 0.55
                     + neonGold * strand * (1.0 - abs(sin(lon * 2.0))) * 0.35;
    float3 particles = (neonBlue * 0.55 + neonViolet * 0.35) * dots * 1.2;
    float3 rim = (neonBlue + neonViolet) * halo * 0.42;
    float3 surface = body + filaments + particles + rim;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 8 — Wireframe globe: cyan meridians/parallels over a dark
// interior, inspired by neon wire-mesh planet references.
fragment float4 mockup_planet_wireframeGlobe_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float facing = clamp(dot(N, V), 0.0, 1.0);

    float2 lonLat = mockup_sphere_lon_lat(N);
    float line = mockup_wireframe_line_mask(lonLat, 14.0, 9.0);
    // Secondary hex-ish diagonal lattice.
    float diag = abs(sin(lonLat.x * 9.0 + lonLat.y * 7.0))
               + abs(cos(lonLat.x * 7.0 - lonLat.y * 8.0));
    float diagLine = 1.0 - smoothstep(0.15, 0.22, abs(diag - 1.0)) * 0.35;

    float3 wire = float3(0.22, 0.92, 1.05);
    float3 interior = float3(0.01, 0.03, 0.06) + in.color.rgb * 0.04 * facing;
    float3 gridGlow = wire * saturate(line + diagLine * 0.45);
    float edge = pow(1.0 - facing, 3.5);
    float3 surface = interior + gridGlow * (0.55 + edge * 0.35);
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 9 — Matte gradient: satin mint-shifted body with a soft top
// highlight and darker lower hemisphere, inspired by the floating matte
// bead reference (AccountColor still tints the body).
fragment float4 mockup_planet_matteGradient_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(float3(0.35, 0.82, 0.48));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float NdotL = max(0.0, dot(N, L));
    float facing = clamp(dot(N, V), 0.0, 1.0);

    float3 mintShift = mix(in.color.rgb, float3(0.55, 0.88, 0.72), 0.42);
    float highlightLift = pow(max(0.0, dot(N, normalize(L + float3(0.0, 0.35, 0.12)))), 6.0);
    float lowerFalloff = smoothstep(-0.35, 0.55, N.y);
    float3 albedo = mintShift * mix(0.72, 1.08, highlightLift) * lowerFalloff;
    float3 lit = albedo * (0.38 + NdotL * 0.42);
    float spec = pow(max(0.0, dot(N, normalize(L + V))), 48.0) * 0.08;
    float3 surface = lit + float3(spec);
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// Variant 10 — Liquid obsidian: glossy black with animated ripple normals
// and sharp studio specular, inspired by the liquid-glass sphere reference.
fragment float4 mockup_planet_liquidObsidian_fragment(
    PlanetOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    texture2d<float> glyphTexture [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]
) {
    float3 N = normalize(in.worldNormal);
    float time = uniforms.viewportTimeScale.z;
    float ripple = sin(dot(N, float3(3.1, 1.7, 2.4)) * 6.0 + time * 1.1)
                   + sin(dot(N, float3(1.9, 4.2, 0.8)) * 5.0 - time * 0.9) * 0.6;
    float3 tangent = normalize(cross(N, float3(0.0, 1.0, 0.0)) + float3(0.001, 0.0, 0.0));
    float3 bitangent = normalize(cross(N, tangent));
    float3 perturbed = normalize(N + tangent * ripple * 0.11 + bitangent * ripple * 0.07);

    float3 L = normalize(float3(0.55, 0.78, 0.42));
    float3 V = normalize(uniforms.cameraPositionAndTier.xyz - in.worldPos);
    float3 H = normalize(L + V);
    float facing = clamp(dot(N, V), 0.0, 1.0);
    float3 base = float3(0.02, 0.02, 0.025) + in.color.rgb * 0.06;
    float spec = pow(max(0.0, dot(perturbed, H)), 120.0);
    float broad = pow(max(0.0, dot(perturbed, H)), 18.0) * 0.12;
    float rim = pow(1.0 - facing, 3.0) * 0.18;
    float3 surface = base + float3(0.92, 0.95, 1.0) * spec * 0.95
                   + float3(0.35, 0.38, 0.42) * broad
                   + float3(0.18, 0.20, 0.24) * rim;
    surface = mockup_apply_glyph_decal_sandbox(
        surface, N, facing, uniforms, in.worldPos,
        in.glyphUV, glyphTexture, glyphSampler
    );
    return float4(surface, 1.0);
}

// MARK: - Meaning-lens metaball body
//
// Each cluster emits a single instance whose geometry is the shared
// unit-icosphere scaled to the cluster's bounding sphere. The fragment
// shader raymarches the camera ray through the bounding volume, summing
// smooth member contributions from a shared member buffer. The visible
// surface is the implicit isosurface where the summed field crosses the
// threshold; alpha is integrated along the ray for a soft volumetric
// look. The result is one 3D blob per cluster whose edges are defined
// by *where the high-affinity members actually are*, not by a fixed
// spherical envelope.

// World-anchored value noise for the emission-gas structure. Two octaves
// of trilinear hash noise are enough for filament/lane texture at the
// cluster scale, and world anchoring means parallax reads as a true 3D
// volume as the camera flies (screen-space noise would swim).
static inline float meaning_gas_hash(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static inline float meaning_gas_noise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = meaning_gas_hash(i);
    float n100 = meaning_gas_hash(i + float3(1.0, 0.0, 0.0));
    float n010 = meaning_gas_hash(i + float3(0.0, 1.0, 0.0));
    float n110 = meaning_gas_hash(i + float3(1.0, 1.0, 0.0));
    float n001 = meaning_gas_hash(i + float3(0.0, 0.0, 1.0));
    float n101 = meaning_gas_hash(i + float3(1.0, 0.0, 1.0));
    float n011 = meaning_gas_hash(i + float3(0.0, 1.0, 1.0));
    float n111 = meaning_gas_hash(i + float3(1.0, 1.0, 1.0));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

static inline float meaning_gas_fbm(float3 p) {
    return 0.64 * meaning_gas_noise(p) + 0.36 * meaning_gas_noise(p * 2.13 + 17.7);
}

vertex MetaballOut meaning_metaball_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device float3* sphereVerts [[buffer(0)]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    const device MeaningMetaballInstance* instances [[buffer(2)]]
) {
    MeaningMetaballInstance instance = instances[iid];
    float3 center = instance.centerRadius.xyz;
    float radius = max(instance.centerRadius.w, 0.0001);
    float3 spherePos = sphereVerts[vid];
    float3 worldPos = center + spherePos * radius;

    MetaballOut out;
    out.position = uniforms.viewProjection * float4(worldPos, 1.0);
    out.worldPos = worldPos;
    out.worldCentroid = center;
    out.boundingRadius = radius;
    out.color = instance.color;
    out.memberRange = instance.memberRange;
    return out;
}

fragment float4 meaning_metaball_fragment(
    MetaballOut in [[stage_in]],
    constant CameraUniforms& uniforms [[buffer(1)]],
    device const MeaningMetaballMember* members [[buffer(2)]]
) {
    // Lock-transition fade, mirroring the cluster-nucleus material:
    // discarding before the raymarch means the settled locked scene pays
    // nothing for the invisible bodies it still carries.
    float clusterVisibility = saturate(uniforms.lockControls.y);
    if (clusterVisibility <= 0.001) {
        discard_fragment();
    }
    int memberCount = int(in.memberRange.y);
    if (memberCount <= 0) {
        discard_fragment();
    }

    float3 cameraPos = uniforms.cameraPositionAndTier.xyz;
    float3 rayDir = normalize(in.worldPos - cameraPos);

    // Robust ray-sphere intersection: handles camera-inside-bounding-sphere
    // too (front faces would be culled in that case, so we'll be running
    // on back faces). Compute both roots and clip to the camera.
    float3 fromCenter = cameraPos - in.worldCentroid;
    float bCoef = dot(fromCenter, rayDir);
    float cCoef = dot(fromCenter, fromCenter) - in.boundingRadius * in.boundingRadius;
    float disc = bCoef * bCoef - cCoef;
    if (disc < 0.0) {
        discard_fragment();
    }
    float sqrtDisc = sqrt(disc);
    float tNear = -bCoef - sqrtDisc;
    float tFar = -bCoef + sqrtDisc;
    if (tFar <= 0.0) {
        discard_fragment();
    }
    float tEntry = max(0.0, tNear);
    float exitDist = tFar - tEntry;
    if (exitDist <= 0.0) {
        discard_fragment();
    }
    float3 entry = cameraPos + rayDir * tEntry;
    int firstMember = int(in.memberRange.x);

    // Load member centers once per fragment rather than re-reading the
    // member buffer inside the raymarch loop below.
    constexpr int MAX_MEMBERS = 24;
    float4 warpedMembers[MAX_MEMBERS];
    memberCount = min(memberCount, MAX_MEMBERS);
    for (int i = 0; i < memberCount; i++) {
        MeaningMetaballMember m = members[firstMember + i];
        float3 memberPosition = m.positionRadius.xyz;
        warpedMembers[i] = float4(memberPosition, m.positionRadius.w);
    }

    // Raymarch the bounding volume, accumulating gas density where the
    // summed member field is present. The step count is stamped per frame
    // into memberRange.w by MeaningMetaballFramePolicy — tier-based
    // (24 / 16 / 12) and halved for small-on-screen bodies. A non-positive
    // w (packet uploaded before any stamping) falls back to the full 24
    // steps for safety.
    //
    // Emission-nebula model (2026-07-21): the members are the light
    // source. A body isosurface forms where members genuinely pack; a
    // wisp band below it lets weakly-attached fringe members trail off as
    // thin gas; world-anchored noise carves filament structure and
    // subtractive dark lanes; dense interiors lift toward white. Hue never
    // varies inside a cluster — luminance carries local density.
    float stampedSteps = in.memberRange.w;
    int steps = stampedSteps <= 0.0 ? 24 : clamp(int(round(stampedSteps)), 6, 24);
    float stepSize = exitDist / float(steps);

    float time = uniforms.viewportTimeScale.z;
    float phase = in.memberRange.z;
    // Slow terrain drift plus the halo pass's 0.16 rad/s atmospheric
    // breath; the pulse rest damp freezes the breath's amplitude at rest
    // so idle scenes hold a canonical midpoint instead of a stray phase.
    float3 drift = float3(time * 0.014, -time * 0.009, time * 0.006);
    float breathe = 0.90 + 0.10 * uniforms.frameVisualLanguage.z * sin(time * 0.16 + phase);
    // Transient hover flare: the hovered cluster lifts, siblings ease
    // back a step (`lockControls.w` = hovered cluster's phase + 1).
    float hoverLane = uniforms.lockControls.w;
    float hovered = (hoverLane > 0.5 && abs(hoverLane - 1.0 - phase) < 0.00005) ? 1.0 : 0.0;
    float anyHover = hoverLane > 0.5 ? 1.0 : 0.0;
    float lift = 1.0 + 0.42 * hovered - 0.20 * (anyHover - hovered);

    float accum = 0.0;
    float glow = 0.0;

    for (int s = 0; s < steps; s++) {
        float t = (float(s) + 0.5) * stepSize;
        float3 p = entry + rayDir * t;

        float field = 0.0;
        for (int i = 0; i < memberCount; i++) {
            float4 member = warpedMembers[i];
            float3 delta = p - member.xyz;
            float r = member.w;
            float r2 = r * r;
            float dist2 = dot(delta, delta);
            if (dist2 < r2) {
                // Smooth quadratic falloff — classic metaball kernel.
                float u = 1.0 - dist2 / r2;
                field += u * u;
            }
        }

        // The noise lookups only run where gas can exist at all — most
        // steps in the bounding sphere are empty and skip them.
        if (field > 0.08) {
            float body = smoothstep(0.42, 0.95, field);
            float wisp = smoothstep(0.08, 0.42, field) * (1.0 - body);
            float structure = 0.32
                + 0.68 * smoothstep(0.18, 0.82, meaning_gas_fbm(p * 7.0 + drift));
            float lanes = 1.0
                - 0.58 * body
                    * smoothstep(0.52, 0.78, meaning_gas_fbm(p * 11.0 - drift * 0.7 + 31.7));
            float dens = (body + wisp * 0.45) * structure * lanes;
            accum += dens * stepSize * 2.1;
            // Dense interiors lift toward white — the emission core.
            glow += smoothstep(1.15, 2.4, field) * structure * stepSize * 2.1;
        }

        // Early termination — once the integrated alpha saturates we can
        // stop marching, the remaining samples can't visibly change the
        // pixel against the translucent body cap.
        if (accum > 0.52) {
            break;
        }
    }

    if (accum < 0.01) {
        discard_fragment();
    }

    bool isContour = in.color.a < 0.0;
    float density = clamp(abs(in.color.a), 0.0, 1.0);
    if (isContour) {
        // Two distinct membership readings: a crisp outer band shows the
        // complete semantic extent, while the restrained inner wash shows
        // where evidence is most concentrated. The transparent interval
        // between them keeps individual message dots legible.
        float outerBand = smoothstep(0.010, 0.035, accum)
            * (1.0 - smoothstep(0.085, 0.155, accum));
        float innerCore = smoothstep(0.22, 0.46, accum);
        float contourAlpha = outerBand * (0.30 + density * 0.12)
            + innerCore * (0.08 + density * 0.08);
        if (contourAlpha < 0.008) {
            discard_fragment();
        }
        float coreLift = min(0.38, glow);
        float3 contourColor = in.color.rgb * (0.86 + 0.24 * density)
            + mix(in.color.rgb, float3(1.0, 0.98, 0.99), 0.62) * coreLift;
        return float4(
            contourColor * lift,
            saturate(contourAlpha * breathe * lift) * clusterVisibility
        );
    }
    // Final alpha — capped low so overlapping cluster bounding spheres
    // don't alpha-stack into one continuous body, and so member stars
    // and fibers drawn after this pass remain readable on top. Where two
    // clusters' gases do overlap, their distinct ramp hues blend into a
    // legible shared-semantics bridge instead of a brighter wall.
    float alpha = min(0.46, accum * (0.50 + density * 0.42)) * breathe * lift;
    float coreLift = min(0.55, glow);
    float3 color = in.color.rgb * (0.78 + 0.30 * density)
        + mix(in.color.rgb, float3(1.0, 0.98, 0.99), 0.72) * coreLift;
    return float4(color * lift, saturate(alpha) * clusterVisibility);
}
