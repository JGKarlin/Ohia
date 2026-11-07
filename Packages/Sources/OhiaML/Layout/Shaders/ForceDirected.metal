#include <metal_stdlib>
using namespace metal;

struct SimParams {
    uint nodeCount;
    uint maxNeighborsPerNode;
    uint negativeSamplesPerNode;
    float restLength;
    float repulsionConstant;
    float velocityDamping;
    float dt;
    uint iterationSeed; // seeds per-node negative-sample RNG
};

// Simple LCG for deterministic per-node negative sampling.
inline uint lcg(uint state) {
    return state * 1664525u + 1013904223u;
}

kernel void force_directed_step(
    device float3*          positions       [[buffer(0)]],
    device float3*          velocities      [[buffer(1)]],
    device const uint*      neighborOffsets [[buffer(2)]], // [nodeCount+1]
    device const uint*      neighborIDs     [[buffer(3)]],
    device const float*     neighborSims    [[buffer(4)]],
    device float*           moveMagnitude   [[buffer(5)]],
    constant SimParams&     params          [[buffer(6)]],
    uint                    gid             [[thread_position_in_grid]]
) {
    if (gid >= params.nodeCount) return;
    float3 pos = positions[gid];
    float3 vel = velocities[gid];
    float3 force = float3(0, 0, 0);

    // Attractive forces on k-NN edges
    uint start = neighborOffsets[gid];
    uint end   = neighborOffsets[gid + 1];
    for (uint i = start; i < end; ++i) {
        uint targetIdx = neighborIDs[i];
        float sim = neighborSims[i];
        float3 d = positions[targetIdx] - pos;
        float dist = length(d) + 1e-6;
        float target = params.restLength * (1.0 - sim);
        force += sim * (dist - target) * (d / dist);
    }

    // Repulsive forces via negative sampling (M random non-neighbors)
    uint rng = gid ^ params.iterationSeed;
    for (uint m = 0; m < params.negativeSamplesPerNode; ++m) {
        rng = lcg(rng);
        uint j = rng % params.nodeCount;
        if (j == gid) continue;
        float3 d = positions[j] - pos;
        float distSq = dot(d, d) + 1e-6;
        float3 repel = params.repulsionConstant / distSq * (d / sqrt(distSq));
        force -= repel;
    }

    // Integrate with damping
    vel = params.velocityDamping * (vel + force * params.dt);
    // Clamp velocity magnitude to prevent divergence
    float vmag = length(vel);
    if (vmag > 1.0) { vel *= (1.0 / vmag); }
    pos += vel * params.dt;
    // Soft boundary spring at cube edges
    for (uint axis = 0; axis < 3; ++axis) {
        float p = pos[axis];
        if (p >  1.0) { pos[axis] =  1.0; vel[axis] *= -0.5; }
        if (p < -1.0) { pos[axis] = -1.0; vel[axis] *= -0.5; }
    }

    positions[gid] = pos;
    velocities[gid] = vel;
    moveMagnitude[gid] = length(vel * params.dt);
}
