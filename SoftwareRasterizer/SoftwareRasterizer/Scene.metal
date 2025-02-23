#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
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
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return half4(intensity, 1);
}

// -----------------------------------------------------------------

struct OutputResolve {
    float4 position [[position]];
};

vertex OutputResolve resolveVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    OutputResolve output;
    output.position = float4(x, y, 0, 1);
    //output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

fragment half4 resolveFS(OutputResolve input [[stage_in]],
                         texture2d<uint, access::read> rasterTex [[texture(0)]])
{
    uint data = rasterTex.read(uint2(input.position.xy)).x;
    //half3 color = half3((data) & 0xFF, (data >> 8) & 0xFF, (data >> 16) & 0xFF) / 255;
    half3 color = (data != 0) ? half3(1, 0, 0) : half3(0, 0, 1);
    return half4(color, 1);
}
