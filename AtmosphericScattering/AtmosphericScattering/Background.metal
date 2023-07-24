#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

vertex Output backgroundVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

#define SunDir (normalize(0.0, 0.5, 0.5))
#define SunIrradiane (10.0)
#define SolarIrradiance (123.0)

#define EarthRadius (6360.0)
#define AtmosphereRadius (EarthRadius + 60.0)
#define RayleighHeightScale (8.0)
#define MieHeightScale (1.2)
#define SigmaSRayleigh (float3(5.8e-6, 1.35e-5, 3.31e-5))
#define SigmaAReyleigh SigmaSRayleigh
#define SigmaSMie (4.0e-6)
#define SigmaAMie (1.1 * SigmaSMie)
#define ThetaMie (0.80h)
#define SunAngularRadius (0.2678 * M_PI_F / 180)
#define MuSMin (cos(102 * M_PI_F / 180))

static float MeterToKM() { return 1000.0; }
static float KMToMeter() { return 1 / 1000.0; }

static half RayleighScatteringPhase(half cosAngle)
{
    return 3 * (1 + cosAngle * cosAngle) / (16 * M_PI_H);
}

static half MieScatteringPhase(half cosAngle)
{
    return (1 - ThetaMie * ThetaMie) / (4 * M_PI_H * pow(1 - ThetaMie * ThetaMie - 2 * ThetaMie * cosAngle, 1.5h));
}
static half MieScatteringPhaseSchlick(half cosAngle)
{
    half k = 1.55h * ThetaMie - 0.55h * ThetaMie * ThetaMie;
    return (1 - k * k) / (4 * M_PI_H * pow(1 + k * cosAngle, 2));
}

static float DistanceToTopAtmosphere(float len, float viewCosAngle)
{
    float discriminant = len * len * (viewCosAngle * viewCosAngle - 1) + (AtmosphereRadius * AtmosphereRadius);
    return -1 * len * viewCosAngle + sqrt(discriminant);
}
static float DistanceToBottomAtmosphere(float len, float viewCosAngle)
{
    float discriminant = len * len * (viewCosAngle * viewCosAngle - 1) + (EarthRadius * EarthRadius);
    return -1 * len * viewCosAngle - sqrt(discriminant);
}

static float2 getRayleighAndMieDensity(float height, float2 heightScale)
{
    float2 d = exp(-1 * height * (1.0 / heightScale));
    return d;
}
static float2 computeRayleighAndMieOpticalDepthToTopAtmosphere(float len, float viewCosAngle)
{
    const ushort SampleCount = 50;
    float rayStep = DistanceToTopAtmosphere(len, viewCosAngle) / SampleCount;
    float2 odRayleighAndMie = 0;
    for (ushort i = 0; i < SampleCount; ++i)
    {
        float d = rayStep * (float)i;
        float r = sqrt(d * d + 2 * len * viewCosAngle*d + len * len);
        float2 heightScale = float2(RayleighHeightScale, MieHeightScale);
        float2 y = getRayleighAndMieDensity(r - EarthRadius, heightScale);
        odRayleighAndMie += y * rayStep;
    }
    return odRayleighAndMie;
}
static float3 computeRayleighAndMieTransmittanceToTopAtmosphere(float len, float viewCosAngle)
{
    float2 od = computeRayleighAndMieOpticalDepthToTopAtmosphere(len, viewCosAngle);
    float4 sigmaS = float4(SigmaSRayleigh, SigmaSMie) * MeterToKM();
    float3 tr = exp(-1 * (od.x * sigmaS.rgb + od.y * sigmaS.aaa));
    return tr;
}
static float2 getTransmittanceTexUVFromRMu(float len, float viewCosAngle)
{
    float h = sqrt(AtmosphereRadius * AtmosphereRadius - EarthRadius * EarthRadius);
    float rho = sqrt(len * len - EarthRadius * EarthRadius);
    float d = DistanceToTopAtmosphere(len, viewCosAngle);
    float d_min = AtmosphereRadius - len;
    float d_max = rho + h;
    float x_mu = (d - d_min) / (d_max - d_min);
    float x_r = rho / h;
    return float2(x_mu, x_r);
}
static float2 getRMuFromTransmittanceTexUV(float2 uv)
{
    float x_mu = uv.x;
    float x_r = uv.y;
    float h = sqrt(AtmosphereRadius * AtmosphereRadius - EarthRadius * EarthRadius);
    float rho = h * x_r;
    float r = sqrt(rho * rho + EarthRadius * EarthRadius);
    float d_min = AtmosphereRadius - r;
    float d_max = rho + h;
    float d = d_min + x_mu * (d_max - d_min);
    float mu = (h * h - rho * rho - d * d) / (2.0 * r * d);
    return float2(r, mu);
}




static half3 getTransmittanceToTopAtmosphereBoundary(float len, float viewCosAngle,
                                                     texture2d<half> transmittanceLut)
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    float2 uv = getTransmittanceTexUVFromRMu(len, viewCosAngle);
    half3 col = transmittanceLut.sample(ss, uv, level(0.0)).rgb;
    return col;
}
static half3 getTransmittance(float len, float viewCosAngle, float d, bool rMuIntersectsGround,
                              texture2d<half> transmittanceLut)
{
    float r = sqrt(d * d + 2 * len * viewCosAngle * d + len * len);
    float mu = (len * viewCosAngle + d) / r;
    if (rMuIntersectsGround) {
        half3 a = getTransmittanceToTopAtmosphereBoundary(r, -1 * mu, transmittanceLut);
        half3 b = getTransmittanceToTopAtmosphereBoundary(len, -1 * viewCosAngle, transmittanceLut);
        return min(a / b, 1.0h);
    }
    else {
        half3 a = getTransmittanceToTopAtmosphereBoundary(len, viewCosAngle, transmittanceLut);
        half3 b = getTransmittanceToTopAtmosphereBoundary(r, mu, transmittanceLut);
        return min(a / b, 1.0h);
    }
}
static half3 getTransmittanceToSun(float len, float viewCosAngle,
                                   texture2d<half> transmittanceLut)
{
    float sinThetaH = EarthRadius / len;
    float cosThetaH = -1 * sqrt(saturate(1 - sinThetaH * sinThetaH));
    float a = -1 * sinThetaH * SunAngularRadius;
    float b = sinThetaH * SunAngularRadius;
    float c = smoothstep(a, b, viewCosAngle - cosThetaH);
    half3 d = getTransmittanceToTopAtmosphereBoundary(len, viewCosAngle, transmittanceLut);
    return c * d;
}

static half2x3 computeSingleScatteirngIntegrated(float r, float mu, float mu_s, float nu, float d,
                                                 bool ray_r_mu_intersects_ground,
                                                 texture2d<half> transmittanceLut)
{
    float r_d = sqrt(d * d + 2 * r * mu * d + r * r);
    float mu_s_d = (r * mu_s + d * nu) / r_d;
    half3 a = getTransmittance(r, mu, d, ray_r_mu_intersects_ground, transmittanceLut);
    half3 b = getTransmittanceToSun(r_d, mu_s_d, transmittanceLut);
    half3 tr = a * b;
    //float4 sigmaS = float4(SigmaSRayleigh, SigmaSMie) * MeterToKM(); // これでいいの？
    float2 heightScale = float2(RayleighHeightScale, MieHeightScale);
    float2 density = getRayleighAndMieDensity(r_d - EarthRadius, heightScale);
    return { half3(tr * density.x), half3(tr * density.y) };
}

static float DistanceToNearestAtmosphereBoundary(float r, float mu, bool ray_r_mu_intersects_ground)
{
    if (ray_r_mu_intersects_ground)
        return DistanceToBottomAtmosphere(r, mu);
    return DistanceToTopAtmosphere(r, mu);
}

static half2x3 computeSingleScattering(float r, float mu, float mu_s, float nu,
                                       bool ray_r_mu_intersects_ground,
                                       texture2d<half> transmittanceLut)
{
    const short SampleCount = 50;
    float stepSize = DistanceToNearestAtmosphereBoundary(r, mu, ray_r_mu_intersects_ground) / SampleCount;
    half3 rayleigh_sum = 0;
    half3 mie_sum = 0;
    for (short i = 0; i < SampleCount; ++i)
    {
        float d = (float)i * stepSize;
        half2x3 s = computeSingleScatteirngIntegrated(r, mu, mu_s, nu, d, ray_r_mu_intersects_ground, transmittanceLut);
        rayleigh_sum += s[0];
        mie_sum += s[1];
    }
    float3 rayleigh = float3(rayleigh_sum) * stepSize * SolarIrradiance * SigmaSRayleigh;
    float3 mie = float3(mie_sum) * stepSize * SolarIrradiance * SigmaSMie;
    return { half3(rayleigh), half3(mie) };
}

static float RayleighPhaseFunction(float nu)
{
    float k = 3 / (16 * M_PI_F); // [1/sr]
    return k * (1 + nu * nu);
}

static float MiePhaseFunction(float nu)
{
    float k = 3 / (8 * M_PI_F) * (1 - ThetaMie * ThetaMie) / (2 + ThetaMie * ThetaMie);
    return k * (1 + nu * nu) / pow(1 + ThetaMie * ThetaMie - 2 * ThetaMie * nu, 1.5);
}

static float4 getScatteringTextureUvwzFromRMuMuSNu(float r, float mu, float mu_s, float nu,
                                                   bool ray_r_mu_intersects_ground)
{
    float h = sqrt(AtmosphereRadius * AtmosphereRadius - EarthRadius * EarthRadius);
    float rho = sqrt(r * r - EarthRadius * EarthRadius);
    float u_r = rho / h;
    float r_mu = r * mu;
    float discriminant = r_mu * r_mu - r * r + EarthRadius * EarthRadius;
    float u_mu;
    if (ray_r_mu_intersects_ground)
    {
        float d = -1 * r_mu - sqrt(discriminant);
        float d_min = r - EarthRadius;
        float d_max = rho;
        u_mu = 0.5 - 0.5 * (d - d_min) / (d_max - d_min);
    }
    else
    {
        float d = -1 * r_mu + sqrt(discriminant + h * h);
        float d_min = AtmosphereRadius - r;
        float d_max = rho + h;
        u_mu = 0.5 + 0.5 * (d - d_min) / (d_max - d_min);
    }
    float d = DistanceToTopAtmosphere(EarthRadius, mu_s);
    float d_min = AtmosphereRadius - EarthRadius;
    float d_max = h;
    float a = (d - d_min) / (d_max - d_min);
    float D = DistanceToTopAtmosphere(EarthRadius, MuSMin);
    float A = (D - d_min) / (d_max - d_min);
    float u_mu_s = max(1 - a / A, 0.0) / (1 + a);
    float u_nu = (nu + 1) / 2;
    return float4(u_nu, u_mu_s, u_mu, u_r);
}

static float4 getRMuMuSNuFromScatteringTextureUvwz(float4 uvwz, thread bool& ray_r_mu_intersects_ground)
{
    float h = sqrt(AtmosphereRadius * AtmosphereRadius - EarthRadius * EarthRadius);
    float rho = h * uvwz.w;
    float r = sqrt(rho * rho + EarthRadius * EarthRadius);
    float mu;
    if (uvwz.z < 0.5)
    {
        float d_min = r - EarthRadius;
        float d_max = rho;
        float d = d_min + (d_max - d_min) * (1 - 2 * uvwz.z) * 2;
        mu = -1 * (rho * rho + d * d) / (2 * r * d);
        ray_r_mu_intersects_ground = true;
    }
    else
    {
        float d_min = AtmosphereRadius - r;
        float d_max = rho + h;
        float d = d_min + (d_max - d_min) * (2 * uvwz.z - 1) * 2;
        mu = (h * h - rho * rho - d * d) / (2 * r * d);
        ray_r_mu_intersects_ground = false;
    }
    float x_mu_s = uvwz.y;
    float d_min = AtmosphereRadius - EarthRadius;
    float d_max = h;
    float D = DistanceToTopAtmosphere(EarthRadius, MuSMin);
    float A = (D - d_min) / (d_max - d_min);
    float a = (A - x_mu_s * A) / (1 + x_mu_s * A);
    float d = d_min + min(a, A) * (d_max - d_min);
    float mu_s = (h * h - d * d) / (2 * EarthRadius * d);
    float nu = uvwz.z * 2 - 1;
    return float4(r, mu, mu_s, nu);
}

static float4 getRMuMuSNuFromScatteringTextureFragCoord(float3 fragCoord, thread bool& ray_r_mu_intersects_ground)
{
    float scattering_texture_mu_s_size = 1.0;
    float frag_coord_nu = floor(fragCoord.x / scattering_texture_mu_s_size);
    float frag_coord_mu_s = modf(fragCoord.x, scattering_texture_mu_s_size);
    float4 uvwz = float4(frag_coord_nu, frag_coord_mu_s, fragCoord.yz);
    float4 rMuMuSNu = getRMuMuSNuFromScatteringTextureUvwz(uvwz, ray_r_mu_intersects_ground);
    float mu = rMuMuSNu.y, mu_s = rMuMuSNu.z, nu = rMuMuSNu.w;
    nu = clamp(nu, mu * mu_s - sqrt((1 - mu * mu) * (1 - mu_s * mu_s)),
               mu * mu_s + sqrt((1 - mu * mu) * (1 - mu_s * mu_s)));
    return float4(rMuMuSNu.xyz, nu);
}

fragment half4 backgroundFS(Output input [[stage_in]],
                            texture2d<half> transmittanceLut [[texture(0)]])
{
    const half azimth = input.texcoord.x;
    const half height = input.texcoord.y;
    float2 r_mu = getRMuFromTransmittanceTexUV(input.texcoord);
    float3 tr = computeRayleighAndMieTransmittanceToTopAtmosphere(r_mu.x, r_mu.y);
    return half4(tr.x, tr.y, tr.z, 1.0);
    
    return half4(0.1, 0.2, 0.4, 1.0);
}
