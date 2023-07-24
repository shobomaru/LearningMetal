#define FIX_FP16_ERROR (1)

struct CScene {
    float4x4 ViewProj;
    float2 Metallic;
    float2 Roughness;
};

struct CLight {
    float3 cameraPosition;
    float3 sunLightIntensity;
    float3 sunLightDirection;
};

ConstantBuffer<CScene> SceneCB : register(b0);
ConstantBuffer<CLight> LightCB : register(b1);

struct Input {
    float3 position : Position;
    float3 normal : Normal;
    float2 texcoord : TexCoord;
};

struct Output {
    float4 position : SV_Position;
    float3 world : World;
    half3 normal : Normal;
    float2 texcoord : TexCoord;
    half metallic : Metallic;
    half roughness : Roughness;
    half2 clearCoat : ClearCoat;
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

StructuredBuffer<float3x4> InstanceMat : register(t0);

Output sceneVS(Input input,
               uint16_t instanceID : SV_InstanceID)
{
    const float4x4 wmat = { InstanceMat[instanceID][0], InstanceMat[instanceID][1], InstanceMat[instanceID][2], {0, 0, 0, 1} };
    const float4 wpos = mul(float4(input.position, 1), wmat);
    if (instanceID >= 18) {
        instanceID = 5;
    }
    Output output = (Output)0;
    output.position = mul(wpos, SceneCB.ViewProj);
    output.world = wpos.xyz / wpos.w;
    output.normal = mul(half3(input.normal), GetNormalMatrix(wmat));
    output.texcoord = input.texcoord;
    output.metallic = (half)lerp(SceneCB.Metallic[0], SceneCB.Metallic[1], saturate((float)(instanceID / 6)));
    output.roughness = (half)lerp(SceneCB.Roughness[0], SceneCB.Roughness[1], (float)(instanceID % 6) / 5);
    output.clearCoat = half2((instanceID >= 12 && instanceID < 18) ? 1 : 0, 0.1/*roughness*/);
    return output;
}

#define M_PI_H ((half)(3.14159265))

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
    return saturate(0.5h / (GGXV + GGXL));
}
half3 F_Schlick(half u, half3 f0, half f90 = 1.0)
{
    return f0 + (1.0h - f0) * pow(1.0h - u, 5.0h);
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

Texture2D<half4> Tex;
SamplerState SS;

half4 sceneFS(Output input) : SV_Target
{
    half4 baseColor = Tex.Sample(SS, input.texcoord);
    half3 diffColor = (input.metallic > 0.0) ? 0.0 : baseColor.rgb;
    half3 specColor = (input.metallic > 0.0) ? baseColor.rgb : (F0).xxx;
    half3 normal = normalize(input.normal);
    
    half3 viewDir = (half3)normalize(LightCB.cameraPosition - input.world);
    half3 halfVector = normalize(viewDir + (half3)LightCB.sunLightDirection);
    half dotNV = abs(dot(normal, viewDir)) + 1e-5h;
    half dotNL = saturate(dot(normal, (half3)LightCB.sunLightDirection));
    half dotNH = saturate(dot(normal, halfVector));
    half dotLH = saturate(dot((half3)LightCB.sunLightDirection, halfVector));
    // https://ubm-twvideo01.s3.amazonaws.com/o1/vault/gdc2017/Presentations/Hammon_Earl_PBR_Diffuse_Lighting.pdf
    half lenSq_LV = 2 + 2 * dot((half3)LightCB.sunLightDirection, viewDir);
    half rcpLen_LV = rsqrt(lenSq_LV);
    dotNH = (dotNL + dotNV) * rcpLen_LV;
    dotLH = rcpLen_LV + rcpLen_LV * dot((half3)LightCB.sunLightDirection, viewDir);
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
    half termFc = F_Schlick(dotLH, (F0).xxx).r * clearCoatStrength;
    half Frc = termDc * termVc * termFc;
    
    //half3 F = Fr + Fd * diffColor; // Diffuse + Specular
    half3 F = (Fr + Fd * diffColor) * (1 - termFc) + Frc;
    float3 lit = LightCB.sunLightIntensity * (float3)F * (float3)dotNL;
    
    return half4((half3)lit, 1.0);
}
