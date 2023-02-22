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
    half4 blend1 [[color(1), raster_order_group(0)]];
    half4 blend2 [[color(2), raster_order_group(0)]];
    half4 blend3 [[color(3), raster_order_group(0)]];
    float4 depth [[color(4), raster_order_group(0)]];
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
    float depth = input.position.z / input.position.w;
    intensity = mix(half3(0.5), intensity, saturate(2000.0 * depth - 18.5));
    
    half4 color = half4(intensity * alpha, alpha); // Pre-multiplied alpha
    float4 depthList = pixelInput.depth;
    short insertIndex = -1;
    if (depthList.x <= depth) {
        insertIndex = 0;
        depthList = float4(depth, depthList.xyz);
    }
    else if (depthList.y <= depth) {
        insertIndex = 1;
        depthList = float4(depthList.x, depth, depthList.yz);
    }
    else if (depthList.z <= depth) {
        insertIndex = 2;
        depthList = float4(depthList.xy, depth, depthList.z);
    }
    else if (depthList.w <= depth) {
        insertIndex = 3;
        depthList = float4(depthList.xyz, depth);
    }
    else {
        discard_fragment(); // TODO: Is this works efficiently?
    }
    
    PixelOutput output;
    if (insertIndex == 3) {
        output.blend3 = color;
        output.blend2 = pixelInput.blend2;
        output.blend1 = pixelInput.blend1;
        output.color = pixelInput.color;
    }
    else if (insertIndex == 2) {
        output.blend3 = pixelInput.blend2;
        output.blend2 = color;
        output.blend1 = pixelInput.blend1;
        output.color = pixelInput.color;
    }
    else if (insertIndex == 1) {
        output.blend3 = pixelInput.blend2;
        output.blend2 = pixelInput.blend1;
        output.blend1 = color;
        output.color = pixelInput.color;
    }
    else if (insertIndex == 0) {
        output.blend3 = pixelInput.blend2;
        output.blend2 = pixelInput.blend1;
        output.blend1 = pixelInput.color;
        output.color = color;
    }
    else {
        output = pixelInput;
    }
    output.depth = depthList;
    
    return output;
}
