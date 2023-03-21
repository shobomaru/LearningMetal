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

struct ColorOutput {
    half4 rt0 [[color(0)]];
    half4 rt1 [[color(1)]];
};

struct CScene {
    float4x4 viewProj;
};

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      ushort vid [[vertex_id]],
                      constant float3x4* instanceWorldMat [[buffer(2)]],
                      ushort instanceID [[instance_id]])
{
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceID][0], instanceWorldMat[instanceID][1], instanceWorldMat[instanceID][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    float4 wpos = float4(input.position, 1) * worldMat;
    Output output;
    output.position = wpos * scene.viewProj;
    output.world = wpos.xyz;
    output.normal = half3(input.normal);
    return output;
}

fragment ColorOutput sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return {
        .rt0 = half4(intensity, 1),
        .rt1 = half4(normalize(input.normal) * 0.5 + 0.5, 1), // unorm
    };
}
