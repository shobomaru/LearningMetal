#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
    float2 texcoord;
};

struct CScene {
    float4x4 viewProj;
};

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    output.world = input.position;
    output.normal = half3(input.normal);
    output.texcoord = input.texcoord;
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]],
                       texture2d<half> tex [[texture(0)]],
                       sampler ss [[sampler(0)]])
{
    half4 intensity = tex.sample(ss, input.texcoord);
    return half4(intensity.rgb, 1);
}
