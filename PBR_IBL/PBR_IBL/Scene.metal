#include <metal_stdlib>
using namespace metal;

#define FIX_FP16_ERROR (1)

struct CScene {
    float4x4 ViewProj;
    packed_float2 Metallic;
    packed_float2 Roughness;
};

struct CLight {
    float3 cameraPosition;
    float3 sunLightIntensity;
    float3 sunLightDirection;
};

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
    half metallic;
    half roughness;
    half2 clearCoat;
};

struct ColorAttachments {
    half4 lightAccum [[color(1)]];
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

vertex Output sceneVS(Input input [[stage_in]],
                      ushort instanceID [[instance_id]],
                      ushort baseInstance [[base_instance]],
                      constant float3x4* instanceMat [[buffer(1)]],
                      constant CScene& constants [[buffer(2)]])
{
    const float4x4 wmat = { instanceMat[instanceID][0], instanceMat[instanceID][1], instanceMat[instanceID][2], {0, 0, 0, 1} };
    const float4 wpos = float4(input.position, 1) * wmat;
    if (instanceID >= 18) {
        instanceID = 5;
    }
    return Output {
        .position = wpos * constants.ViewProj,
        .world = wpos.xyz / wpos.w,
        .normal = half3(input.normal) * GetNormalMatrix(wmat),
        .texcoord = input.texcoord,
        .metallic = (half)mix(constants.Metallic[0], constants.Metallic[1], saturate((float)(instanceID / 6))),
        .roughness = (half)mix(constants.Roughness[0], constants.Roughness[1], (float)(instanceID % 6) / 5),
        .clearCoat = half2((instanceID >= 12 && instanceID < 18) ? 1 : 0, 0.1/*roughness*/),
    };
}

// https://google.github.io/filament/Filament.html
#define F0 (0.04h)
half D_GGX(half NoH, half3 NxH, half a)
{
#if FIX_FP16_ERROR
    half a2 = NoH * a;
    half k = a / (dot(NxH, NxH) + a2 * a2);
    half d = k * k / M_PI_H;
    return min(d, 65504.0h);
#else
    half a2 = a * a;
    half f = (NoH * a2 - NoH) * NoH + 1.0h;
    return a2 / (M_PI_H * f * f + 1e-5); // avoid nan
#endif
}
half V_SmithGGXCorrelated(half NoV, half NoL, half roughness)
{
    half a2 = roughness * roughness;
    half GGXV = NoL * sqrt(NoV * NoV * (1.0h - a2) + a2);
    half GGXL = NoV * sqrt(NoL * NoL * (1.0h - a2) + a2);
    return 0.5h / (GGXV + GGXL + HALF_MIN);
}
half3 F_Schlick(half u, half3 f0, half f90 = 1.0)
{
    return f0 + (1.0h - f0) * pow(1.0h - u, 5.0h);
}
half Fd_Lambert() {
    return 1 / M_PI_H;
}
half Fd_Burley(half NoV, half NoL, half LoH, half roughness)
{
    half f90 = 0.5h + 2.0h * roughness * LoH * LoH;
    half lightScatter = F_Schlick(NoL, 1.0h, f90).x;
    half viewScatter = F_Schlick(NoV, 1.0h, f90).x;
    return lightScatter * viewScatter / M_PI_H;
}
half V_Kelemen(half LoH)
{
    return 0.25h / (LoH * LoH);
}
float computeLODFromRoughness(half perceptualRoughness)
{
    constexpr float MaxEnvMapMipLevel = 7.0;
    return (perceptualRoughness * MaxEnvMapMipLevel);
}
half3 ApproximateSpecularIBL(half3 SpecularColor, half Roughness, half3 N, half3 V, thread half2& EnvBRDF,
                              texture2d<half> envBrdfTex, texturecube<half> prefilteredTex)
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    constexpr sampler ssWrap(filter::linear, mip_filter::linear, address::repeat);
    
    half NoV = saturate(dot(N, V));
    half3 R = 2 * dot(V, N) * N - V;
    float lod = computeLODFromRoughness(Roughness);
    auto m = prefilteredTex.get_num_mip_levels();
    half3 PrefilteredColor = prefilteredTex.sample(ssWrap, float3(R), level(lod)).rgb;
    EnvBRDF = envBrdfTex.sample(ss, float2(NoV, Roughness * Roughness), level(0.0)).rg;
    return PrefilteredColor * (SpecularColor * EnvBRDF.x + EnvBRDF.y);
}
struct SHFloat
{
    float f[9];
    thread const float& operator [](const int i) const {
        return f[i];
    }
    thread float& operator [](const int i) {
        return f[i];
    }
};
half irradianceSH(half3 n, thread const SHFloat& sh)
{
    float c =  sh[0]
        + sh[1] * n.y
        + sh[2] * n.z
        + sh[3] * n.x
#if 1
        + sh[4] * (n.y * n.x)
        + sh[5] * (n.y * n.z)
        + sh[6] * (3 * n.z * n.z - 1)
        + sh[7] * (n.z * n.x)
        + sh[8] * (n.x * n.x - n.y * n.y)
#endif
        ;
    return half(max(0.0, c) / M_PI_F);
}
half3 lightingSH(half3 n, SHFloat shR, SHFloat shG, SHFloat shB)
{
    half r = irradianceSH(n, shR);
    half g = irradianceSH(n, shG);
    half b = irradianceSH(n, shB);
    return half3(r, g, b);
}
fragment ColorAttachments sceneFS(Output input [[stage_in]],
                                  constant CLight& constants [[buffer(0)]],
                                  constant SHFloat* shBuf [[buffer(1)]],
                                  texture2d<half> tex [[texture(0)]],
                                  texture2d<half> envBrdfTex [[texture(3)]],
                                  texturecube<half> prefilteredTex [[texture(4)]],
                                  sampler ss [[sampler(0)]])
{
    half4 baseColor = 1;//tex.sample(ss, input.texcoord); // Albedo 100%
    half3 diffColor = (input.metallic > 0.0) ? 0.0 : baseColor.rgb;
    half3 specColor = (input.metallic > 0.0) ? baseColor.rgb : half3(F0);
    half3 normal = normalize(input.normal);
    
    half3 viewDir = (half3)normalize(constants.cameraPosition - input.world);
    half3 halfVector = normalize(viewDir + (half3)constants.sunLightDirection);
    half dotNV = abs(dot(normal, viewDir)) + 1e-5h;
    half dotNL = saturate(dot(normal, (half3)constants.sunLightDirection));
    half dotNH = saturate(dot(normal, halfVector));
    half dotLH = saturate(dot((half3)constants.sunLightDirection, halfVector));
    // https://ubm-twvideo01.s3.amazonaws.com/o1/vault/gdc2017/Presentations/Hammon_Earl_PBR_Diffuse_Lighting.pdf
    half lenSq_LV = 2 + 2 * dot((half3)constants.sunLightDirection, viewDir);
    half rcpLen_LV = rsqrt(lenSq_LV);
    dotNH = (dotNL + dotNV) * rcpLen_LV;
    dotLH = rcpLen_LV + rcpLen_LV * dot((half3)constants.sunLightDirection, viewDir);
    half roughness = input.roughness * input.roughness;
    half3 crossNH = cross(normal, halfVector);
    half termD = D_GGX(dotNH, crossNH, roughness);
    half termV = V_SmithGGXCorrelated(dotNV, dotNL, roughness);
    half3 termF = F_Schlick(dotLH, specColor);
    half3 Fr = termD * termV * termF;
    half Fd = Fd_Burley(dotNV, dotNL, dotLH, roughness);
    
    half clearCoatStrength = input.clearCoat.x;
    half clearCoatPerceptualRoughness = input.clearCoat.y;
    half clearCoatRoughness = clearCoatPerceptualRoughness * clearCoatPerceptualRoughness;
    half termDc = D_GGX(dotNH, crossNH, clearCoatRoughness);
    half termVc = V_Kelemen(dotLH);
    half termFc = F_Schlick(dotLH, half3(F0)).r * clearCoatStrength;
    half Frc = termDc * termVc * termFc;
    
    //half3 F = Fr + Fd * diffColor; // Diffuse + Specular
    half3 F = (Fr + Fd * diffColor) * (1 - termFc) + Frc;
    
    float3 lit = 0;//constants.sunLightIntensity * (float3)F * (float3)dotNL; // IBL only
    half Fc = F_Schlick(dotNH, F0).r * clearCoatStrength;
    half2 envBrdf, envBrdfClearCoat;
    half3 litS = ApproximateSpecularIBL(specColor, half(input.roughness), normal, viewDir, envBrdf, envBrdfTex, prefilteredTex) * (1 - Fc) * (1 - Fc);
    half3 litSc = ApproximateSpecularIBL((half3)1, clearCoatRoughness, normal, viewDir, envBrdfClearCoat, envBrdfTex, prefilteredTex) * Fc;
    half3 specReflectance = specColor;
    half3 sh = lightingSH(normal, shBuf[0], shBuf[1], shBuf[2]);
    half3 litD = sh * diffColor * (1 - specReflectance) * Fd_Lambert() * (1 - Fc) * (1 - Fc);
    lit += float3(litSc + litS + litD);
    
    ColorAttachments output = { half4((half3)lit, 1.0) };
    return output;
}
