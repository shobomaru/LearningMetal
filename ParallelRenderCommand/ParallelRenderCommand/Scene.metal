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

struct CMesh {
    float3x4 world;
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      constant CMesh &mesh [[buffer(2)]],
                      uint vid [[vertex_id]])
{
    const float4x4 worldMat = float4x4(mesh.world[0], mesh.world[1], mesh.world[2], float4(0, 0, 0, 1));
    Output output;
    output.position = float4(input.position, 1) * worldMat * scene.viewProj;
    output.world = output.position.xyz / output.position.w;
    output.normal = normalize(half3(input.normal) * GetNormalMatrix(worldMat));
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return half4(intensity, 1);
}
