#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

vertex Output filterVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

fragment float4 stretchFS(Output input [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          constant float& threshold [[buffer(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(ss, input.texcoord);
    color -= threshold;
    color = max(color, 0.0);
    return color;
}

fragment float4 blurFS(Output input [[stage_in]],
                       texture2d<float> tex [[texture(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float4 color = 0;
    for (int y = -3; y <= 3; ++y) {
        for (int x = -3; x <= 3; ++x) {
            color += tex.sample(ss, input.texcoord, int2(x, y));
        }
    }
    color /= 49.0;
    return color;
}
