#include <metal_stdlib>
using namespace metal;

struct CBParticleSim {
    float2 birthPosition;
    float step;
    uint maxParticles;
};

struct ParticleElement {
    float2 position;
    float2 direction;
    float2 birthPosition;
    float time;
    half amplitude;
    short division;
};

struct Output {
    float4 position [[position]];
    float2 xy;
    half amplitude [[flat]];
};

vertex Output heightVS(constant ParticleElement* pt [[buffer(0)]],
                       constant float &particleSize [[buffer(1)]],
                       constant CBParticleSim& constants [[buffer(2)]],
                       uint vid [[vertex_id]],
                       uint instanceID [[instance_id]])
{
    if (instanceID >= constants.maxParticles)
    {
        Output output {};
        output.position.w = 1.0 / 0.0;
        return output;
    }
    
    float x = (vid & 2) ? 1.0 : -1.0;
    float y = (vid & 1) ? 1.0 : -1.0;
    //float2 texcoord = float2(x, y) * float2(1, -1) * 0.5 + 0.5;
    
    Output output;
    output.position = float4(float2(x, y) * particleSize + pt[instanceID].position, 0, 1);
    output.xy = float2(x, y);
    output.amplitude = pt[instanceID].amplitude;
    return output;
}

fragment half4 heightFS(Output input [[stage_in]])
{
    float amp = 0.0;
    float dist = saturate(length(input.xy));
    if (dist < 1.0)
    {
        amp = cos(2.0 * M_PI_F * 0.75 * dist) * input.amplitude;
    }
    if (abs(amp) < 0.01)
    {
        discard_fragment();
    }
    return half4(amp, 1, 1, 1);
}

vertex float4 normalVS(ushort vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    return float4(x, y, 0, 1);
}

fragment float4 normalFS(float4 pos [[position]],
                         texture2d<half> tex)
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    
    float w = tex.get_width();
    float h = tex.get_height();
    float2 pitch = 1.0 / float2(w, h);
    float2 uv = pos.xy / float2(w, h);
    
    float rl = tex.sample(ss, uv + float2(pitch.x, 0), level(0.0)).r;
    rl -= tex.sample(ss, uv + float2(-pitch.x, 0), level(0.0)).r;
    float tb = tex.sample(ss, uv + float2(0, pitch.y), level(0.0)).r;
    tb -= tex.sample(ss, uv + float2(0, -pitch.y), level(0.0)).r;
    
    float3 n = float3(rl, 0.5, tb);
    return float4(normalize(n), 1);
}

