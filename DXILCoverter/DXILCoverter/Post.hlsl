struct Output {
    float4 position : SV_Position;
    float2 texcoord : TexCoord;
};

struct ColorAttachments {
    half4 lightAccum : SV_Target;
};

Output postVS(uint vid : SV_VertexID)
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

// http://filmicworlds.com/blog/filmic-tonemapping-operators/
half luminance(half3 rgb) {
    return dot(rgb, half3(0.2, 0.7, 0.1));
}
#define TONEMAPPING_W (11.2)
half3 tonemapping(half3 z) {
    half a = 0.15, b = 0.50, c = 0.10, d = 0.20, e = 0.02, f = 0.30;
    return ((z * (a * z + c * b) + d * e) / (z * (a * z + b) + d * f)) - e / f;
}
half3 linearToSrgb(half3 lin) {
    lin = saturate(lin);
    half3 s1 = 1.055 * pow(lin, 1 / 2.4) - 0.055;
    half3 s2 = lin * 12.92;
    half r = (lin.r < 0.0031308 ? 1 : 0) * s2.r + (lin.r >= 0.0031308 ? 1 : 0) * s1.r;
    half g = (lin.g < 0.0031308 ? 1 : 0) * s2.g + (lin.g >= 0.0031308 ? 1 : 0) * s1.g;
    half b = (lin.b < 0.0031308 ? 1 : 0) * s2.b + (lin.b >= 0.0031308 ? 1 : 0) * s1.b;
    return half3(r, g, b);
}

Texture2D<half4> LightAccumTex;

half4 postFS(Output input) : SV_Target
{
    half4 lightAccum = LightAccumTex.Load(int3(input.position.xy, 0));
    if (lightAccum.a == 0.0)
    {
        return half4(lightAccum.rgb, 1);
    }
    else
    {
        half3 color = lightAccum.rgb;
        half exposure = exp2(0.0); // fixed
        color = tonemapping(exposure * color) / tonemapping(TONEMAPPING_W).r;
        color = min(color, 65504);
        color = linearToSrgb(color);
        return half4(color, 1);
    }
}
