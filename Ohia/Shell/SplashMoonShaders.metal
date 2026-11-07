#include <metal_stdlib>
using namespace metal;

struct SplashOrbUniforms {
    float4 color;
    float4 light;
    float4 rimColor;
    float4 phaseTime;
};

struct SplashOrbOut {
    float4 position [[position]];
    float3 normal;
};

vertex SplashOrbOut splashMoonVertex(
    uint vertexID [[vertex_id]],
    const device float3 *vertices [[buffer(0)]],
    constant SplashOrbUniforms& uniforms [[buffer(1)]]
) {
    float3 p = vertices[vertexID];

    float yaw = uniforms.phaseTime.x * 6.2831853;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float3 rotated = float3(
        p.x * cy + p.z * sy,
        p.y,
        -p.x * sy + p.z * cy
    );

    float tilt = -0.24;
    float ct = cos(tilt);
    float st = sin(tilt);
    rotated = float3(
        rotated.x,
        rotated.y * ct - rotated.z * st,
        rotated.y * st + rotated.z * ct
    );

    SplashOrbOut out;
    out.position = float4(rotated.xy * 0.98, 0.50 - rotated.z * 0.38, 1.0);
    out.normal = normalize(rotated);
    return out;
}

fragment float4 splashMoonFragment(
    SplashOrbOut in [[stage_in]],
    constant SplashOrbUniforms& uniforms [[buffer(0)]]
) {
    float3 N = normalize(in.normal);
    float3 L = normalize(uniforms.light.xyz);
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H = normalize(L + V);

    float NdotL = max(0.0, dot(N, L));
    float ambient = 0.14;
    float3 lit = uniforms.color.rgb * (ambient + NdotL * 0.86);

    float spec = pow(max(0.0, dot(N, H)), 6.0);
    float3 highlight = (uniforms.color.rgb * 1.20 + float3(0.06, 0.06, 0.08)) * spec * 0.28;

    float facing = clamp(dot(N, V), 0.0, 1.0);
    float rim = pow(1.0 - facing, 3.2);
    float3 rimContrib = uniforms.rimColor.rgb * rim * 0.18;

    float terminator = smoothstep(-0.28, 0.18, dot(N, L));
    float3 nightSide = uniforms.color.rgb * 0.10;
    float3 surface = mix(nightSide, lit + highlight, terminator) + rimContrib;

    return float4(surface, 1.0);
}
