#include <metal_stdlib>
using namespace metal;

#define NumSampleCount (1024)

struct Output {
    float4 position [[position]];
    float2 texcoord;
    ushort rtIndex [[render_target_array_index]];
};

// https://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
half3 importanceSampleGGX(half2 Xi, half Roughness, half3 N)
{
    half a = Roughness * Roughness;
    half Phi = 2 * M_PI_H * Xi.x;
    half CosTheta = sqrt( (1 - Xi.y) / ( 1 + (a*a - 1) * Xi.y ) );
    half SinTheta = sqrt( 1 - CosTheta * CosTheta );
    half3 H;
    H.x = SinTheta * cos( Phi );
    H.y = SinTheta * sin( Phi );
    H.z = CosTheta;
    half3 UpVector = abs(N.z) < 0.999 ? half3(0,0,1) : half3(1,0,0);
    half3 TangentX = normalize( cross( UpVector, N ) );
    half3 TangentY = cross( N, TangentX );
    // Tangent to world space
    return TangentX * H.x + TangentY * H.y + N * H.z;
}
half2 hammersley(uint i, half numSamples) {
    return half2(i / numSamples, half(reverse_bits(i) / float(0xFFFFFFFFu)));
}
half GDFG(half NoV, half NoL, half a) {
    half a2 = a * a;
    half GGXL = NoV * sqrt((-NoL * a2 + NoL) * NoL + a2);
    half GGXV = NoL * sqrt((-NoV * a2 + NoV) * NoV + a2);
    return (2 * NoL) / (GGXV + GGXL + HALF_MIN);
}
half2 DFG(half NoV, half a) {
    const half3 N = half3(0, 0, 1);
    half3 V;
    V.x = sqrt(1.0f - NoV*NoV);
    V.y = 0.0f;
    V.z = NoV;
    float2 r = 0.0f;
    for (ushort i = 0; i < NumSampleCount; i++) {
        half2 Xi = hammersley(i, NumSampleCount);
        half3 H = importanceSampleGGX(Xi, a, N);
        half3 L = 2 * dot(V, H) * H - V;
        half VoH = saturate(dot(V, H));
        half NoL = saturate(L.z);
        half NoH = saturate(H.z);
        if (NoL > 0.0h) {
            half G = GDFG(NoV, NoL, a);
            half Gv = G * VoH / NoH;
            half Fc = pow(1 - VoH, 5.0h);
            r.x += Gv * (1 - Fc);
            r.y += Gv * Fc;
        }
    }
    return half2(r * (1.0 / NumSampleCount));
}
fragment half2 ambientBrdfFS(Output input [[stage_in]])
{
    float perceptualRoughness = input.texcoord.x;
    float roughness = perceptualRoughness * perceptualRoughness;
    float dotNV = input.texcoord.y;
    return DFG(roughness, dotNV);
}

#define EnvMapBaseSampleCount (6144)
#define EnvMapClampLuminance (500)

half3 directionFrom3D(half x, half y, ushort z) {
    switch (z) {
    case 0: return half3(+1, -y, -x);
    case 1: return half3(-1, -y, +x);
    case 2: return half3(+x, +1, +y);
    case 3: return half3(+x, -1, -y);
    case 4: return half3(+x, -y, +1);
    case 5: return half3(-x, -y, -1);
    }
    return (half3)0;
}
half3 PrefilterEnvMap(half Roughness, half3 R, texturecube<half> tex, half lv, ushort sampleCount) {
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    half3 N = R;
    half3 V = R;
    float3 PrefilteredColor = 0;
    float TotalWeight = 0;
    for (ushort i = 0; i < sampleCount; i++) {
        half2 Xi = hammersley(i, sampleCount);
        half3 H = importanceSampleGGX(Xi, Roughness, N);
        half3 L = 2 * dot(V, H) * H - V;
        half NoL = saturate(dot(N, L));
        if (NoL > 0) {
            half3 c = min((half)EnvMapClampLuminance, tex.sample(ss, float3(L), level(lv)).rgb) * NoL;
            PrefilteredColor += float3(c);
            TotalWeight += NoL;
        }
    }
    return half3(PrefilteredColor / TotalWeight);
}
fragment half3 envMapFilterFS(Output input [[stage_in]],
                              constant uint& mipLevel [[buffer(0)]],
                              texturecube<half> tex)
{
    // Artifact and performance control parameter
    half sampleFactor[8] = { 0.3, 0.85, 1.0, 0.7, 0.4, 0.3, 0.1, 0.05 };
    ushort sampleCount = (ushort)(sampleFactor[mipLevel] * EnvMapBaseSampleCount);
    
    // Excpect mip count == 8 (128x128)
    half roughness = ((half)(mipLevel) + 0.5h) / 8;
    uint level = max(0u, mipLevel - 1);
    half3 dir = directionFrom3D(input.texcoord.x * 2 - 1, input.texcoord.y * 2 - 1, input.rtIndex);
    return PrefilterEnvMap(roughness, normalize(dir), tex, half(level), sampleCount);
}

#define IrradianceMapNumSampleCount (3072)
#define IrradianceMapClampLuminance (4000)
#define IrradianceMapSampleMipLevel (2)

void importanceSampleCosDir(half2 u, half3 N, thread half3& L, thread half& NdotL, thread half& pdf)
{
    // Local referencial
    half3 upVector = abs(N.z) < 0.999 ? half3(0,0,1) : half3(1,0,0);
    half3 tangentX = normalize(cross(upVector, N));
    half3 tangentY = cross(N, tangentX);
    half u1 = u.x;
    half u2 = u.y;
    half r = sqrt(u1);
    half phi = u2 * M_PI_H * 2;
    half3 L0 = half3(r * cos(phi), r * sin(phi), sqrt(max(0.0h, 1 - u1)));
    L = normalize(tangentX * L0.x + tangentY * L0.y + N * L0.z);
    NdotL = dot(L, N);
    pdf = NdotL / M_PI_H;
}
float3 integrateDiffuseCube(half3 N, texturecube<half> tex) {
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float3 accBrdf = 0;
    for (ushort i = 0; i < IrradianceMapNumSampleCount; i++) {
        half2 eta = hammersley(i, IrradianceMapNumSampleCount);
        half3 L;
        half NdotL, pdf;
        importanceSampleCosDir(eta, N, L, NdotL, pdf);
        if (NdotL > 0) {
            half3 c = min(IrradianceMapClampLuminance, tex.sample(ss, float3(L), level(IrradianceMapSampleMipLevel)).rgb);
            accBrdf += float3(c);
        }
    }
    return (accBrdf / IrradianceMapClampLuminance);
}
fragment half3 irradianeMapFS(Output input [[stage_in]],
                              texturecube<half> tex [[texture(0)]])
{
    half3 dir = directionFrom3D(input.texcoord.x * 2 - 1, input.texcoord.y * 2 - 1, input.rtIndex);
    float3 c = integrateDiffuseCube(normalize(dir), tex);
    return half3(c);
}

