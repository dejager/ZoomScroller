#include <metal_stdlib>
using namespace metal;

// Uniform layout matches TransitRenderer.
struct MediaMapping {
    float4 crop;   // upright aspect-fill XY, base mip level
    float4 rowX;
    float4 rowY;
};
struct CameraTap {
    float4 from;   // inverse magnification, cosine, sine, radial curvature
    float4 to;
    float4 mix;    // arrival, total exposure weight
};
struct Print {
    float4 viewport; // pixel dimensions, short side in pixels, display scale
    float4 finish;   // progress, outgoing seed, incoming seed, dust/dirt bitmask
    MediaMapping from, to;
    float brightness;
};
struct PlateVertex { float4 position [[position]]; float2 uv; };

vertex PlateVertex transitScreen(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2u, id & 2u);
    return {float4(uv * float2(2,-2) + float2(-1,1), 0, 1), uv};
}

constexpr sampler mediaSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

float2 encodedUV(float2 uv, constant MediaMapping &m) {
    return float2(dot(m.rowX.xy, uv) + m.rowX.z, dot(m.rowY.xy, uv) + m.rowY.z);
}

// Inverse barrel projection is monotone along a radius, including the far corners.
half3 imageAt(texture2d<half> image, float2 ray, float radius2, float2 axes,
              constant MediaMapping &mapping, float4 camera) {
    float2 p = ray * (camera.x * rsqrt(1.0 + camera.w * radius2));
    p = float2(camera.y*p.x - camera.z*p.y, camera.z*p.x + camera.y*p.y) / axes;
    float2 offset = p * mapping.crop.xy;
    float2 beyond = max(abs(offset)-.5, 0.0);
    float2 reflected = .5 + clamp(offset,-.5,.5) - sign(offset)*beyond/(1.0+36.0*beyond);
    float lod = mapping.crop.z + log2(camera.x) + log2(1.0 + 160.0*max(beyond.x,beyond.y));
    return image.sample(mediaSampler, encodedUV(reflected,mapping), level(max(lod,0.0))).rgb;
}

float hashCell(float2 cell, float seed) {
    float3 p = fract(float3(cell.xyx + seed) * float3(.1031,.1030,.0973));
    p += dot(p,p.yzx+33.33);
    return fract((p.x+p.y)*p.z);
}

float2 emulsion(float2 film, float seed, float travel, uint flags) {
    float dust = 0, dirt = 0;
    if (flags & 1u) {
        float2 v = film * 49 + float2(.39,-.58)*travel;
        float2 cell = floor(v);
        float random = hashCell(cell,seed);
        float2 center = .13 + .74*float2(hashCell(cell+19,seed),hashCell(cell-31,seed));
        float d = distance(fract(v),center);
        dust = step(.91,random) * (1-smoothstep(.012,.097,d)) * .23;
    }
    if (flags & 2u) {
        float2 v = film * 10 + float2(-.21,.13)*travel;
        float2 cell = floor(v);
        float random = hashCell(cell+23,seed);
        float2 local = fract(v) - float2(.5,.49);
        local.x += .13*sin(local.y*8+random*6);
        float d = length(local * float2(3.5,1.1));
        dirt = step(.93, random) * (1-smoothstep(.055,.22,d)) * .17;
    }
    return float2(dust,dirt);
}

half3 finish(half3 color, float2 uv, constant Print &u, float arrival) {
    uint flags = uint(u.finish.w);
    if (flags == 0) return color;
    float2 film = uv*u.viewport.xy/u.viewport.z;
    float2 marks = float2(0);
    if (arrival < 1) marks += (1-arrival)*emulsion(film,u.finish.y,u.finish.x,flags);
    if (arrival > 0) marks += arrival*emulsion(film,u.finish.z,u.finish.x-1,flags);
    return color * half(1-marks.y) + half(marks.x) * (1-color);
}

fragment half4 transitHold(PlateVertex in [[stage_in]], constant Print &u [[buffer(0)]],
                           texture2d<half> image [[texture(0)]]) {
    float2 uv = (in.uv-.5)*u.from.crop.xy + .5;
    half3 color = image.sample(mediaSampler,encodedUV(uv,u.from),level(max(0.0,u.from.crop.z))).rgb;
    return half4(finish(color,in.uv,u,0),1);
}

fragment half4 transitExposure(PlateVertex in [[stage_in]], constant Print &u [[buffer(0)]],
                               constant CameraTap *taps [[buffer(1)]], constant uint &count [[buffer(2)]],
                               texture2d<half> first [[texture(0)]], texture2d<half> second [[texture(1)]]) {
    // Unit radius at the far corner for every aspect ratio.
    float2 axes = 2*u.viewport.xy/length(u.viewport.xy);
    float2 ray = (in.uv-.5)*axes;
    float radius2 = dot(ray,ray);
    // Develop the next exposure from the optical center toward the corners.
    float radialDelay = .19*(saturate(radius2)-.37);
    half3 exposure = 0;
    float arrival = 0;
    for (uint i=0; i<count; ++i) {
        CameraTap tap = taps[i];
        float mixValue = smoothstep(.30+radialDelay,.70+radialDelay,tap.mix.x);
        half3 color = 0;
        if (mixValue < 1) color += half(1-mixValue)*imageAt(first,ray,radius2,axes,u.from,tap.from);
        if (mixValue > 0) color += half(mixValue)*imageAt(second,ray,radius2,axes,u.to,tap.to);
        exposure += half(tap.mix.y)*color;
        arrival += tap.mix.y*mixValue;
    }
    return half4(finish(exposure,in.uv,u,arrival)*half(u.brightness),1);
}

struct Ink {
    float4 geometry; // inverse-depth dolly, roll, opacity, width in pixels
    float4 viewport; // pixel dimensions, short side, scale
    float4 label;    // resting text quad origin and size (normalized viewport)
    float brightness;
};
struct Cubic { float4 a, b; }; // xy/zw pairs for start, control1, control2, end
struct StrokeVertex {
    float4 position [[position]];
    float edge [[center_no_perspective]];
    float opacity;
};

vertex StrokeVertex transitStroke(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                  constant Ink &ink [[buffer(0)]], device const Cubic *curves [[buffer(1)]]) {
    Cubic c = curves[instanceID];
    float t = float(vertexID >> 1)/64.0;
    float2 a=mix(c.a.xy,c.a.zw,t), b=mix(c.a.zw,c.b.xy,t), d=mix(c.b.xy,c.b.zw,t);
    float2 ab=mix(a,b,t), bd=mix(b,d,t);
    float2 q=mix(ab,bd,t)-.5, tangent=3*(bd-ab);
    // A tilted plane has affine inverse depth in the rest image. This preserves the
    // author's normalized control points at rest; near and far ends separate as we dolly.
    constexpr float2 tilt = float2(.70,-.58);
    float invDepth = .98 + dot(q,tilt);
    float divisor = max(.16,1.0-ink.geometry.x*invDepth);
    float2 pos = q/divisor;
    float2 dir = tangent*divisor + q*ink.geometry.x*dot(tangent,tilt);
    float s=sin(ink.geometry.y), co=cos(ink.geometry.y);
    float2x2 rotation=float2x2(float2(co,s),float2(-s,co));
    float2 px = rotation*(pos*ink.viewport.xy);
    float2 axis = rotation*(dir*ink.viewport.xy);
    float2 normal=float2(-axis.y,axis.x)/max(length(axis),.00001);
    float edge=(vertexID&1u ? 1.0 : -1.0)*(ink.geometry.w+1.25);
    px += normal*edge;
    return {float4(px / ink.viewport.xy * float2(2,-2),0,1),edge,ink.geometry.z};
}

fragment half4 transitHairline(StrokeVertex in [[stage_in]], constant Ink &ink [[buffer(0)]]) {
    float aa=max(.30,.5*fwidth(in.edge));
    half opacity=half(in.opacity*(1-smoothstep(ink.geometry.w-aa,ink.geometry.w+aa,abs(in.edge))));
    return half4(half3(.98,.95,.89)*opacity*half(ink.brightness),opacity);
}

vertex PlateVertex transitTypeQuad(uint id [[vertex_id]],constant Ink &ink [[buffer(0)]]) {
    float2 uv=float2(id&1u,id>>1u);
    float2 pos=(ink.label.xy + uv*ink.label.zw - .5)/(1-.42*ink.geometry.x);
    return {float4(pos*float2(2,-2),0,1),uv};
}
fragment half4 transitType(PlateVertex in [[stage_in]],constant Ink &ink [[buffer(0)]],
                           texture2d<half> letters [[texture(0)]]) {
    half coverage=letters.sample(mediaSampler,in.uv).r;
    half shadow=letters.sample(mediaSampler,in.uv-float2(.9/letters.get_width(),1.5/letters.get_height())).r;
    half alpha=(coverage+(1-coverage)*shadow*.60h)*half(ink.geometry.z);
    return half4(half3(.98,.97,.95)*coverage*half(ink.geometry.z)*half(ink.brightness),alpha);
}
