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
                                ushort sid [[thread_index_in_simdgroup]],
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
    
#if 0
    uint idx = atomic_fetch_add_explicit(outNumParticles, 1, memory_order_relaxed);
#else
    simd_vote vote = simd_active_threads_mask();
    simdgroup_barrier(mem_flags::mem_none);
    
    // Currently Apple GPU has 32 SIMD lane, but consider 64 SIMD lane just in case
    uint2 vote2 = uint2((simd_vote::vote_t)vote & 0xFFffFFff, (simd_vote::vote_t)vote >> 32);
    
    // The shader statistics says (A) has 3 less instructions than (B)
    uint prefixIdx = simd_prefix_exclusive_sum(1u); // (A)
    //uint prefixIdx = popcount(vote2.x & ~((1u << sid) - 1u)); // (B)
    //prefixIdx += (sid >= 32) ? popcount(vote2.y & ~((1u << (sid - 32)) - 1u)) : 0; // (B)
    
    uint idxBase = 0;
    if (simd_is_first()) {
        uint count = popcount(vote2.x) + popcount(vote2.y);
        idxBase = atomic_fetch_add_explicit(outNumParticles, count, memory_order_relaxed);
    }
    idxBase = simd_broadcast_first(idxBase);
    simdgroup_barrier(mem_flags::mem_none);
    
    uint idx = idxBase + prefixIdx;
#endif
    outParticles[idx] = pt;
}
