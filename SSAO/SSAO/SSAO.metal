#include <metal_stdlib>
using namespace metal;

#define NumAOSamples (4)

struct CBSSAO {
    float4x4 viewMat;
    float4x4 invProj;
    float4x4 invViewProj;
    float aoStrength;
};

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

vertex Output ssaoVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

// Interleaved Gradient Noise
// http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare
// Alan Wolfe's improvement
// https://blog.demofox.org/2022/01/01/interleaved-gradient-noise-a-different-kind-of-low-discrepancy-sequence/
// Copyright 2019 Alan Wolfe
//
//Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

float2 CalcAOSampleUV(float2 uv, float2 svpos, ushort sampleID, float4x4 invViewProj)
{
    float csRadius = 0.035;
    float aspect = invViewProj[1][1] / invViewProj[0][0];
#if 0
    // Fixed pattern, useful for debug
    auto ofs = float2(cos(2 * M_PI_H * sampleID / NumAOSamples), sin(2 * M_PI_H * sampleID / NumAOSamples));
    return saturate(uv + ofs * csRadius);
#else
    // IGN pattern
    float x = svpos.x + 5.588238 * float(sampleID);
    float y = svpos.y + 5.588238 * float(sampleID);
    float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    float a = fract(magic.z * fract(dot(float2(x, y), magic.xy)));
    float rotY;
    float rotX = sincos(2 * M_PI_F * a, rotY);
    return saturate(uv + float2(rotX * aspect, rotY) * csRadius);
#endif
}

// The Alchemy Screen-Space Ambient Obscurance Algorithm
// https://casual-effects.com/research/McGuire2011AlchemyAO/VV11AlchemyAO.pdf

fragment half4 ssaoFS(Output input [[stage_in]],
                      texture2d<float> texZ [[texture(0)]],
                      texture2d<half> texNormal [[texture(1)]],
                      texture2d<half> texColor [[texture(2)]],
                      constant CBSSAO& constants [[buffer(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    
    const float2 uv = input.texcoord;
    const float deviceZ = texZ.sample(ss, uv, level(0.0)).r;
    
    // View space position
    float4 C = float4(uv * 2 - 1, deviceZ, 1) * constants.invProj;
    C.xyz /= C.w;
    
    // View space normal
    const half3 wsNormal = texNormal.sample(ss, input.texcoord, level(0.0)).rgb * 2 - 1;
    const half3 N = normalize(wsNormal * GetNormalMatrix(constants.viewMat)) * half3(1, -1, 1);
    // You can use screen space derivatives instead
    //const float3 N = normalize(cross(dfdy(C.xyz), dfdx(C.xyz)));
    
    half sum = 0.0;
    for (ushort i = 0; i < NumAOSamples; ++i)
    {
        float2 uv2 = CalcAOSampleUV(uv, input.position.xy, i, constants.invViewProj);
        float z2 = texZ.sample(ss, uv2, level(0)).r;
        float4 P = float4(uv2 * 2 - 1, z2, 1) * constants.invProj;
        P.xyz /= P.w;
        
        float3 V = P.xyz - C.xyz;
        float beta = 0.0005;
        float raySq = dot(V, V) + 0.0001;
        float dist = dot(float3(N), V) - deviceZ * beta;
        half ao = max(0.0, dist / raySq);
        sum += ao;
    }
    
    const half sigma = 0.7;
    const half k = 0.5;
    float A = pow(saturate(1 - 2 * sigma * sum / NumAOSamples), k);
    
    half4 color = texColor.sample(ss, uv, level(0.0));
    color = color * mix(1.0, A, constants.aoStrength);
    return color;
}
