#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

struct PixelOutput {
    half4 color [[color(0), raster_order_group(0)]];
    half4 blend1 [[color(1), raster_order_group(0)]];
    half4 blend2 [[color(2), raster_order_group(0)]];
    half4 blend3 [[color(3), raster_order_group(0)]];
    float4 depth [[color(4), raster_order_group(0)]];
};

vertex Output blendVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

fragment half4 blendFS(Output input [[stage_in]],
                       PixelOutput pixelInput)
{
    half4 color = half(0);
    
    // Programmable blending
    if (pixelInput.depth.z != 0)
    {
        color.rgb = pixelInput.blend3.rgb;
    }
    if (pixelInput.depth.y != 0)
    {
        color.rgb = color.rgb * pixelInput.blend2.a + pixelInput.blend2.rgb;
    }
    if (pixelInput.depth.x != 0)
    {
        color.rgb = color.rgb * pixelInput.blend1.a + pixelInput.blend1.rgb;
    }
    //
    {
        color.rgb = color.rgb * pixelInput.color.a + pixelInput.color.rgb;
    }
    
    return color;
}
