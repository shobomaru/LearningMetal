#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float3 world;
    float2 texcoord;
};

struct CDraw {
    float3 minXYZ;
    float3 maxXYZ;
};

struct CScene {
    float4x4 viewProj;
};

constant uint NumQuads [[function_constant(0)]];

vertex Output drawVS(constant CDraw &draw [[buffer(0)]],
                     constant CScene &scene [[buffer(1)]],
                     texture2d<half> heightMap [[texture(0)]],
                     ushort vid [[vertex_id]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    
    ushort xidx = vid % (NumQuads + 1);
    ushort zidx = vid / (NumQuads + 1);
    float2 uv = float2(float(xidx) / NumQuads, float(zidx) / NumQuads);
    half height = heightMap.sample(ss, uv, level(0.0)).r;
    
    float3 wpos = mix(draw.minXYZ, draw.maxXYZ, float3(uv.x, 0, uv.y));
    wpos.y += height;
    Output output;
    output.position = float4(wpos, 1) * scene.viewProj;
    output.world = wpos;
    output.texcoord = uv;
    return output;
}

fragment half4 drawFS(Output input [[stage_in]],
                      texture2d<half> normalMap [[texture(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    
    half3 n = normalMap.sample(ss, input.texcoord, level(0.0)).rgb;
    half3 intensity = n * 0.5 + 0.5;
    return half4(intensity, 1);
}
