/*
 * aobake.c - offline per-vertex ambient occlusion + direct-light visibility
 * baker for the PortalAlley destination (run by Tools/assetgen/bake.py).
 *
 *   aobake <tris.f32> <recv.f32> <lights.f32> <out.f32> <aoRays> <aoDist> <shadowSamples>
 *
 * tris.f32    float[nTri*9]           occluder triangles (portal space, metres)
 * recv.f32    float[nRecv*6]          receiver position + normal
 * lights.f32  float[nLight*8]         pos.xyz, radius, colour*intensity.rgb, weightScale
 * out.f32     float[nRecv*2]          ao in [0,1] (1 = open), vis in [0,1] (1 = lit)
 *
 * AO: cosine-weighted hemisphere rays; a hit at distance t occludes by
 * (1 - t/aoDist)^2, so nearby geometry darkens and distant geometry fades.
 * Visibility: for each authored point light, the same attenuation/window and
 * Lambert term the runtime shader uses gives a weight; soft shadow rays
 * (jittered over a small emitter sphere) give the light's visibility; the
 * result is the weight-averaged visibility, i.e. "how much of the direct light
 * this vertex receives reaches it unblocked".
 *
 * BVH: binned SAH, iterative traversal, any-hit for shadow rays.
 * Deterministic: per-vertex hashed sample sequence, no global RNG state.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float x, y, z; } v3;
static inline v3 V(float x, float y, float z) { v3 r = {x, y, z}; return r; }
static inline v3 add(v3 a, v3 b) { return V(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline v3 sub(v3 a, v3 b) { return V(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline v3 mul(v3 a, float s) { return V(a.x * s, a.y * s, a.z * s); }
static inline float dot(v3 a, v3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline v3 cross(v3 a, v3 b) { return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static inline float len(v3 a) { return sqrtf(dot(a, a)); }
static inline v3 nrm(v3 a) { float l = len(a); return l > 1e-12f ? mul(a, 1.0f / l) : a; }
static inline float minf(float a, float b) { return a < b ? a : b; }
static inline float maxf(float a, float b) { return a > b ? a : b; }

typedef struct { v3 a, e1, e2; } Tri;
typedef struct { v3 lo, hi; int left, first, count; } Node; /* leaf if count > 0 */

static Tri *T;
static int *idx;
static v3 *cen;
static Node *nodes;
static int nnodes;

static void bounds_of(int first, int count, v3 *lo, v3 *hi) {
    *lo = V(1e30f, 1e30f, 1e30f); *hi = V(-1e30f, -1e30f, -1e30f);
    for (int i = first; i < first + count; i++) {
        Tri *t = &T[idx[i]];
        v3 p[3] = {t->a, add(t->a, t->e1), add(t->a, t->e2)};
        for (int k = 0; k < 3; k++) {
            lo->x = minf(lo->x, p[k].x); lo->y = minf(lo->y, p[k].y); lo->z = minf(lo->z, p[k].z);
            hi->x = maxf(hi->x, p[k].x); hi->y = maxf(hi->y, p[k].y); hi->z = maxf(hi->z, p[k].z);
        }
    }
}

static float area(v3 lo, v3 hi) {
    v3 d = sub(hi, lo);
    if (d.x < 0) return 0;
    return 2.0f * (d.x * d.y + d.y * d.z + d.z * d.x);
}

#define BINS 12
static void build(int ni) {
    Node *n = &nodes[ni];
    bounds_of(n->first, n->count, &n->lo, &n->hi);
    if (n->count <= 4) return;
    v3 clo = V(1e30f, 1e30f, 1e30f), chi = V(-1e30f, -1e30f, -1e30f);
    for (int i = n->first; i < n->first + n->count; i++) {
        v3 c = cen[idx[i]];
        clo.x = minf(clo.x, c.x); clo.y = minf(clo.y, c.y); clo.z = minf(clo.z, c.z);
        chi.x = maxf(chi.x, c.x); chi.y = maxf(chi.y, c.y); chi.z = maxf(chi.z, c.z);
    }
    float best = 1e30f; int bestAxis = -1; float bestSplit = 0;
    for (int ax = 0; ax < 3; ax++) {
        float lo = ((float *)&clo)[ax], hi = ((float *)&chi)[ax];
        if (hi - lo < 1e-6f) continue;
        int cnt[BINS] = {0};
        v3 blo[BINS], bhi[BINS];
        for (int b = 0; b < BINS; b++) { blo[b] = V(1e30f, 1e30f, 1e30f); bhi[b] = V(-1e30f, -1e30f, -1e30f); }
        float sc = BINS / (hi - lo);
        for (int i = n->first; i < n->first + n->count; i++) {
            Tri *t = &T[idx[i]];
            int b = (int)((((float *)&cen[idx[i]])[ax] - lo) * sc);
            if (b >= BINS) b = BINS - 1;
            cnt[b]++;
            v3 p[3] = {t->a, add(t->a, t->e1), add(t->a, t->e2)};
            for (int k = 0; k < 3; k++) {
                blo[b].x = minf(blo[b].x, p[k].x); blo[b].y = minf(blo[b].y, p[k].y); blo[b].z = minf(blo[b].z, p[k].z);
                bhi[b].x = maxf(bhi[b].x, p[k].x); bhi[b].y = maxf(bhi[b].y, p[k].y); bhi[b].z = maxf(bhi[b].z, p[k].z);
            }
        }
        for (int s = 1; s < BINS; s++) {
            v3 llo = V(1e30f, 1e30f, 1e30f), lhi = V(-1e30f, -1e30f, -1e30f), rlo = llo, rhi = lhi;
            int lc = 0, rc = 0;
            for (int b = 0; b < s; b++) if (cnt[b]) {
                lc += cnt[b];
                llo.x = minf(llo.x, blo[b].x); llo.y = minf(llo.y, blo[b].y); llo.z = minf(llo.z, blo[b].z);
                lhi.x = maxf(lhi.x, bhi[b].x); lhi.y = maxf(lhi.y, bhi[b].y); lhi.z = maxf(lhi.z, bhi[b].z);
            }
            for (int b = s; b < BINS; b++) if (cnt[b]) {
                rc += cnt[b];
                rlo.x = minf(rlo.x, blo[b].x); rlo.y = minf(rlo.y, blo[b].y); rlo.z = minf(rlo.z, blo[b].z);
                rhi.x = maxf(rhi.x, bhi[b].x); rhi.y = maxf(rhi.y, bhi[b].y); rhi.z = maxf(rhi.z, bhi[b].z);
            }
            if (!lc || !rc) continue;
            float cost = lc * area(llo, lhi) + rc * area(rlo, rhi);
            if (cost < best) { best = cost; bestAxis = ax; bestSplit = lo + s / sc; }
        }
    }
    if (bestAxis < 0 || best >= n->count * area(n->lo, n->hi)) {
        if (n->count <= 16 || bestAxis < 0) return;  /* leaf */
    }
    int i = n->first, j = n->first + n->count - 1;
    while (i <= j) {
        if (((float *)&cen[idx[i]])[bestAxis] < bestSplit) i++;
        else { int t = idx[i]; idx[i] = idx[j]; idx[j] = t; j--; }
    }
    int lc = i - n->first;
    if (lc == 0 || lc == n->count) return;
    int l = nnodes++, r = nnodes++;
    nodes[l].first = n->first; nodes[l].count = lc;
    nodes[r].first = i; nodes[r].count = n->count - lc;
    n->left = l; n->count = 0;
    build(l);
    build(r);
}

static inline int box_hit(const Node *n, v3 o, v3 inv, float tmax) {
    float t1 = (n->lo.x - o.x) * inv.x, t2 = (n->hi.x - o.x) * inv.x;
    float tmin = minf(t1, t2), tm = maxf(t1, t2);
    t1 = (n->lo.y - o.y) * inv.y; t2 = (n->hi.y - o.y) * inv.y;
    tmin = maxf(tmin, minf(t1, t2)); tm = minf(tm, maxf(t1, t2));
    t1 = (n->lo.z - o.z) * inv.z; t2 = (n->hi.z - o.z) * inv.z;
    tmin = maxf(tmin, minf(t1, t2)); tm = minf(tm, maxf(t1, t2));
    return tm >= maxf(tmin, 0.0f) && tmin < tmax;
}

/* Moller-Trumbore, two-sided */
static inline float tri_hit(const Tri *t, v3 o, v3 d, float tmin, float tmax) {
    v3 p = cross(d, t->e2);
    float det = dot(t->e1, p);
    if (fabsf(det) < 1e-12f) return -1;
    float inv = 1.0f / det;
    v3 s = sub(o, t->a);
    float u = dot(s, p) * inv;
    if (u < 0 || u > 1) return -1;
    v3 q = cross(s, t->e1);
    float v = dot(d, q) * inv;
    if (v < 0 || u + v > 1) return -1;
    float tt = dot(t->e2, q) * inv;
    return (tt > tmin && tt < tmax) ? tt : -1;
}

/* closest hit distance (or -1); anyhit: return first hit */
static float trace(v3 o, v3 d, float tmin, float tmax, int anyhit) {
    v3 inv = V(1.0f / (fabsf(d.x) > 1e-12f ? d.x : 1e-12f), 1.0f / (fabsf(d.y) > 1e-12f ? d.y : 1e-12f),
               1.0f / (fabsf(d.z) > 1e-12f ? d.z : 1e-12f));
    int stack[96], sp = 0;
    stack[sp++] = 0;
    float best = -1;
    while (sp) {
        const Node *n = &nodes[stack[--sp]];
        if (!box_hit(n, o, inv, tmax)) continue;
        if (n->count) {
            for (int i = n->first; i < n->first + n->count; i++) {
                float t = tri_hit(&T[idx[i]], o, d, tmin, tmax);
                if (t > 0) { best = t; tmax = t; if (anyhit) return t; }
            }
        } else {
            stack[sp++] = n->left;
            stack[sp++] = n->left + 1;
        }
    }
    return best;
}

static inline uint32_t hash(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}
static inline float rnd(uint32_t *s) { *s = hash(*s + 0x9e3779b9U); return (*s >> 8) * (1.0f / 16777216.0f); }

static void basis(v3 n, v3 *t, v3 *b) {
    v3 a = fabsf(n.x) > 0.9f ? V(0, 1, 0) : V(1, 0, 0);
    *t = nrm(cross(a, n));
    *b = cross(n, *t);
}

static void *readall(const char *path, long *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *size = ftell(f); fseek(f, 0, SEEK_SET);
    void *buf = malloc(*size > 0 ? *size : 1);
    if (fread(buf, 1, *size, f) != (size_t)*size) { perror(path); exit(1); }
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 8) { fprintf(stderr, "usage: aobake tris recv lights out aoRays aoDist shadowSamples\n"); return 2; }
    long sz;
    float *tf = readall(argv[1], &sz); int ntri = (int)(sz / 36);
    float *rf = readall(argv[2], &sz); int nrecv = (int)(sz / 24);
    float *lf = readall(argv[3], &sz); int nl = (int)(sz / 32);
    int aoRays = atoi(argv[5]); float aoDist = (float)atof(argv[6]); int shadowN = atoi(argv[7]);

    T = malloc(sizeof(Tri) * ntri); idx = malloc(sizeof(int) * ntri); cen = malloc(sizeof(v3) * ntri);
    for (int i = 0; i < ntri; i++) {
        float *p = tf + 9 * i;
        v3 a = V(p[0], p[1], p[2]), b = V(p[3], p[4], p[5]), c = V(p[6], p[7], p[8]);
        T[i].a = a; T[i].e1 = sub(b, a); T[i].e2 = sub(c, a);
        cen[i] = mul(add(add(a, b), c), 1.0f / 3.0f);
        idx[i] = i;
    }
    nodes = calloc(2 * ntri + 1, sizeof(Node));
    nodes[0].first = 0; nodes[0].count = ntri; nnodes = 1;
    build(0);
    fprintf(stderr, "aobake: %d triangles, %d nodes, %d receivers, %d lights\n", ntri, nnodes, nrecv, nl);

    float *out = malloc(sizeof(float) * 2 * nrecv);
#pragma omp parallel for schedule(dynamic, 256)
    for (int r = 0; r < nrecv; r++) {
        v3 p = V(rf[6 * r], rf[6 * r + 1], rf[6 * r + 2]);
        v3 n = nrm(V(rf[6 * r + 3], rf[6 * r + 4], rf[6 * r + 5]));
        v3 o = add(p, mul(n, 0.004f));
        v3 t, b; basis(n, &t, &b);
        uint32_t seed = hash((uint32_t)r * 747796405U + 2891336453U);
        /* ambient occlusion (stratified cosine hemisphere) */
        int side = (int)ceilf(sqrtf((float)aoRays));
        float occ = 0; int cnt = 0;
        for (int i = 0; i < side; i++) for (int j = 0; j < side; j++) {
            float u1 = (i + rnd(&seed)) / side, u2 = (j + rnd(&seed)) / side;
            float rr = sqrtf(u1), ph = 6.2831853f * u2;
            v3 d = nrm(add(add(mul(t, rr * cosf(ph)), mul(b, rr * sinf(ph))), mul(n, sqrtf(maxf(0.0f, 1.0f - u1)))));
            float h = trace(o, d, 0.002f, aoDist, 0);
            if (h > 0) { float k = 1.0f - h / aoDist; occ += k * k; }
            cnt++;
        }
        float ao = 1.0f - occ / cnt;
        /* direct-light visibility, weighted like the runtime shader */
        float wsum = 0, vsum = 0;
        for (int l = 0; l < nl; l++) {
            float *L = lf + 8 * l;
            v3 lp = V(L[0], L[1], L[2]);
            float rad = L[3];
            v3 dl = sub(lp, p);
            float d = len(dl);
            if (d < 1e-4f || d > rad) continue;
            v3 ld = mul(dl, 1.0f / d);
            float ndl = dot(n, ld);
            if (ndl <= 0) continue;
            float x = d / rad, win = 1.0f - x * x * x * x; win = win > 0 ? win * win : 0;
            float att = win / (d * d * 0.55f + 0.35f);
            float lum = 0.2126f * L[4] + 0.7152f * L[5] + 0.0722f * L[6];
            float w = att * ndl * lum * L[7];
            if (w < 1e-5f) continue;
            float vis = 0;
            for (int s = 0; s < shadowN; s++) {
                /* jitter over a small emitter sphere: soft penumbrae */
                float a1 = rnd(&seed) * 2 - 1, a2 = rnd(&seed) * 6.2831853f, rr = 0.05f * cbrtf(rnd(&seed));
                float sq = sqrtf(maxf(0.0f, 1.0f - a1 * a1));
                v3 q = add(lp, mul(V(sq * cosf(a2), a1, sq * sinf(a2)), rr));
                v3 sd = sub(q, o);
                float sl = len(sd);
                if (trace(o, mul(sd, 1.0f / sl), 0.002f, sl - 0.03f, 1) < 0) vis += 1;
            }
            vsum += w * vis / shadowN;
            wsum += w;
        }
        out[2 * r] = ao;
        out[2 * r + 1] = wsum > 1e-6f ? vsum / wsum : 1.0f;
    }
    FILE *f = fopen(argv[4], "wb");
    fwrite(out, sizeof(float), 2 * nrecv, f);
    fclose(f);
    return 0;
}
