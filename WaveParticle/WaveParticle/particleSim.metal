#include <metal_stdlib>
using namespace metal;

struct ParticleElement {
    float2 position;
    float2 direction;
    float2 birthPosition;
    float time;
    half amplitude;
    ushort division;
};

struct CBParticleSim {
    float2 birthPosition;
    float step;
    uint maxParticles;
};

constant uint BirthCountPerInstance [[function_constant(0)]];
#define BirthAmplitude (0.20)
#define DieAmplitude (BirthAmplitude * 0.02) // 2%
#define DampingFactor (0.17)
#define SubdivisionTime1 (0.20)
#define SubdivisionTime2 (0.44)

// [numthreads(64,1,1)]
kernel void birthCS(ushort dtid [[thread_position_in_grid]],
                    device ParticleElement* ptOut [[buffer(0)]],
                    device atomic<uint>* ptCount [[buffer(1)]],
                    constant CBParticleSim& constants [[buffer(2)]])
{
    if (dtid >= BirthCountPerInstance)
    {
        return;
    }
    uint idx = atomic_fetch_add_explicit(ptCount, 1, memory_order_relaxed);
    if (idx >= constants.maxParticles)
    {
        return;
    }
    float d = float(dtid) / float(BirthCountPerInstance);
    float2 dir = float2(sin(2 * M_PI_F * d), cos(2 * M_PI_F * d));
    float2 pos = constants.birthPosition + (dir * constants.step / 2);
    ParticleElement pe = {
        .position = pos,
        .direction = dir,
        .birthPosition = constants.birthPosition,
        .amplitude = BirthAmplitude,
        .time = constants.step / 2,
    };
    ptOut[idx] = pe;
}

// [numthreads(64,1,1)]
kernel void genIndirectArgsCS(ushort dtid [[thread_position_in_grid]],
                              device uint* count [[buffer(1)]],
                              device uint* indirectArgs [[buffer(5)]],
                              device uint* ptCountOut [[buffer(4)]],
                              constant CBParticleSim& constants [[buffer(2)]])
{
    if (dtid == 0)
    {
        indirectArgs[0] = (min(*count, constants.maxParticles) + 63) / 64;
        indirectArgs[1] = 1;
        indirectArgs[2] = 1;
        if (*count > constants.maxParticles)
        {
            *count = constants.maxParticles;
        }
        // Reset counter
        *ptCountOut = 0;
    }
}

// [numthreads(64,1,1)]
kernel void updateCS(ushort dtid [[thread_position_in_grid]],
                     constant ParticleElement* pt [[buffer(0)]],
                     constant uint& ptCount [[buffer(1)]],
                     constant CBParticleSim& constants [[buffer(2)]],
                     device ParticleElement* ptOut [[buffer(3)]],
                     device atomic<uint>* ptCountOut [[buffer(4)]])
{
    if (dtid >= ptCount) // TODO: 
    {
        return;
    }
    if (dtid >= min(ptCount, constants.maxParticles - 1))
    {
        return;
    }
    const ParticleElement op = pt[dtid];
    ParticleElement p = op;
    // direction
    float2 dir = p.direction;
    // damping
    float amp = (2.0 - exp(DampingFactor * p.time)) * BirthAmplitude;
    // moving
    float2 pos = p.position + constants.step * p.direction;
    // age
    float time = p.time + constants.step;
    if (amp <= DieAmplitude)
    {
        return;
    }
    // division
    bool doDivision = false;
    float division = p.division;
    if (division == 0 && time >= SubdivisionTime1 && op.time < SubdivisionTime1)
    {
        doDivision = true;
        division = 1;
    }
    else if (division == 1 && time >= SubdivisionTime2 && op.time < SubdivisionTime2)
    {
        doDivision = true;
        division = 2;
    }
    // reflection
    if (abs(pos.x) > 1)
    {
        pos.x = pos.x >= 0 ? 1 : -1;
        dir.x *= -1;
        division = 9;
    }
    if (abs(pos.y) > 1)
    {
        pos.y = pos.y >= 0 ? 1 : -1;
        dir.y *= -1;
        division = 9;
    }
    
    uint idx = atomic_fetch_add_explicit(ptCountOut, 1, memory_order_relaxed);
    if (idx >= constants.maxParticles)
    {
        return;
    }
    p.direction = dir;
    p.position = pos;
    p.amplitude = amp;
    p.time = time;
    p.division = division;
    ptOut[idx] = p;
    
    // Subdivision
    if (division == 1 && doDivision)
    {
        float rad = 2 * M_PI_F / float(BirthCountPerInstance * 2); // half
        float2 dir2;
        dir2.x = op.direction.x * cos(rad) + op.direction.y * -sin(rad);
        dir2.y = op.direction.x * sin(rad) + op.direction.y * cos(rad);
        float2 pos2 = op.birthPosition + dir2 * time;
        
        uint idx2 = atomic_fetch_add_explicit(ptCountOut, 1, memory_order_relaxed);
        if (idx2 >= constants.maxParticles)
        {
            return;
        }
        p.direction = dir2;
        p.position = pos2;
        ptOut[idx2] = p;
    }
    else if (division == 2 && doDivision)
    {
        float rad = 2 * M_PI_F / float(BirthCountPerInstance * 4); // quarter
        float2 dir2;
        dir2.x = op.direction.x * cos(rad) + op.direction.y * -sin(rad);
        dir2.y = op.direction.x * sin(rad) + op.direction.y * cos(rad);
        float2 pos2 = op.birthPosition + dir2 * time;
        
        uint idx2 = atomic_fetch_add_explicit(ptCountOut, 1, memory_order_relaxed);
        if (idx2 >= constants.maxParticles)
        {
            return;
        }
        p.direction = dir2;
        p.position = pos2;
        ptOut[idx2] = p;
    }
}
