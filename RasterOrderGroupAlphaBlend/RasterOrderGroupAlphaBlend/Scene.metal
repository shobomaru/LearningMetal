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

struct PixelOutput {
    half4 color [[color(0), raster_order_group(0)]];
};

struct CScene {
    float4x4 viewProj;
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

vertex Output sceneVS(Input input [[stage_in]],
                      ushort instanceCount [[instance_id]],
                      constant CScene &scene [[buffer(1)]],
                      const device float3x4* instanceWorldMat [[buffer(2)]])
{
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceCount][0], instanceWorldMat[instanceCount][1], instanceWorldMat[instanceCount][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    Output output;
    output.position = float4(input.position, 1) * worldMat * scene.viewProj;
    output.world = output.position.xyz / output.position.w;
    output.normal = normalize(half3(input.normal) * GetNormalMatrix(worldMat));
    return output;
}

fragment PixelOutput sceneFS(Output input [[stage_in]],
                             PixelOutput pixelInput)
{
    half alpha = 0.55;
    //alpha = 1.0; // No blending, useful for debug
    half3 intensity = input.normal * 0.5 + 0.5;
    // Simple depth fade
    intensity = mix(half3(0.5), intensity, saturate(2000.0 * input.position.z / input.position.w - 18.5));
    // Read the current render target
    half4 accum = pixelInput.color;
    // Programmable blending
    accum = accum * (1.0 - alpha) + half4(intensity, 0) * alpha;
    return PixelOutput{ accum };
}
