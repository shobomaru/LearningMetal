#include <metal_stdlib>
using namespace metal;

struct CGpuParticle {
    uint seed;
    uint bufferMax;
    uint spawnRate;
    float speed;
};

struct Particle { // 8byte
    packed_float3 position;
    packed_float3 direction;
    half4 color;
};

// http://www.burtleburtle.net/bob/hash/integer.html
uint32_t hash(uint32_t a)
{
    a = (a ^ 61) ^ (a >> 16);
    a = a + (a << 3);
    a = a ^ (a >> 4);
    a = a * 0x27d4eb2d;
    a = a ^ (a >> 15);
    return a;
}

float getRand(thread uint &a)
{
    a = hash(a);
    union {
        float f;
        uint u;
    } v;
    v.u = (a >> 9) | 0x3F800000/*1.0*/;
    return v.f - 1.0;
}

kernel void gpuParticleSpawnCS(ushort dtid [[thread_position_in_grid]],
                               device Particle* outParticles [[buffer(0)]],
                               device atomic<uint>* numParticles [[buffer(2)]],
                               constant CGpuParticle& constants [[buffer(3)]])
{
    if (dtid < constants.spawnRate)
    {
        uint hash = (constants.seed + dtid);
        uint idx = atomic_fetch_add_explicit(numParticles, 1, memory_order_relaxed);
        if (idx < constants.bufferMax)
        {
            Particle pt = {
                .position = packed_float3(0, 1, 0),
                .direction = normalize(packed_float3(getRand(hash) * 2.0 - 1.0, 0.2 + 0.8 * getRand(hash), getRand(hash) * 2.0 - 1.0)),
                .color = half4(getRand(hash), getRand(hash), getRand(hash), 0),
            };
            outParticles[idx] = pt;
        }
    }
}

kernel void gpuParticleGenIndirectArgsCS(ushort dtid [[thread_position_in_grid]],
                                         device packed_uint3& indirectArgs [[buffer(1)]],
                                         device uint& numParticles [[buffer(2)]],
                                         constant CGpuParticle& constants [[buffer(3)]])
{
    if (dtid == 0)
    {
        uint p = min(numParticles, constants.bufferMax);
        numParticles = p;
        indirectArgs = uint3((p + 63) / 64, 1, 1);
    }
}

kernel void gpuParticleUpdateCS(ushort dtid [[thread_position_in_grid]],
                                constant Particle* inParticles [[buffer(0)]],
                                constant uint& inNumParticles [[buffer(2)]],
                                constant CGpuParticle& constants [[buffer(3)]],
                                device Particle* outParticles [[buffer(4)]],
                                device atomic<uint>* outNumParticles [[buffer(5)]])
{
    if (inNumParticles <= dtid)
    {
        return;
    }
    Particle pt = inParticles[dtid];
    pt.position += pt.direction * constants.speed;
    pt.direction.y -= constants.speed;
    
    // Extinct if particle died
    if (pt.position.y < -5.0)
    {
        return;
    }
    
    uint idx = atomic_fetch_add_explicit(outNumParticles, 1, memory_order_relaxed);
    outParticles[idx] = pt;
}
