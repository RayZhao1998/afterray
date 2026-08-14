// Fragment shader for a ray-marched Schwarzschild black hole with an
// accretion disk. Photons are integrated with the weak-field geodesic
// acceleration  a = -1.5 * h² * r̂ / r⁴  (h = specific angular momentum),
// which reproduces gravitational lensing, the photon sphere halo and the
// disk image wrapped over the top of the hole — the "Gargantua" look.
//
// Kept WebGL1-compatible (GLSL ES 1.00) so it runs everywhere.

export const vertexShaderSource = `
attribute vec2 a_pos;
void main() {
  gl_Position = vec4(a_pos, 0.0, 1.0);
}
`

export const fragmentShaderSource = `
precision highp float;

uniform vec2 u_res;
uniform float u_time;
uniform vec2 u_mouse; // -1..1, parallax

#define RS 1.0            // Schwarzschild radius (scene units)
#define DISK_IN 3.0
#define DISK_OUT 9.0
#define STEPS 160
#define ESCAPE2 900.0

// ---------- hash / noise ----------
float hash13(vec3 p) {
  p = fract(p * 0.1031);
  p += dot(p, p.zyx + 31.32);
  return fract((p.x + p.y) * p.z);
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.55;
  for (int i = 0; i < 5; i++) {
    v += amp * vnoise(p);
    p = p * 2.13 + vec2(17.3, 9.1);
    amp *= 0.5;
  }
  return v;
}

// ---------- background sky (lensed automatically by the geodesic march) ----------
vec3 skyColor(vec3 dir) {
  vec3 col = vec3(0.0);
  for (int layer = 0; layer < 2; layer++) {
    float scale = layer == 0 ? 90.0 : 220.0;
    vec3 cell = floor(dir * scale);
    float h = hash13(cell + float(layer) * 7.7);
    float star = smoothstep(0.994, 1.0, h);
    float twinkle = 0.75 + 0.25 * sin(u_time * (1.0 + 3.0 * fract(h * 13.7)) + h * 40.0);
    col += star * twinkle * (layer == 0 ? 0.85 : 0.4) * vec3(0.9, 0.93, 1.0);
  }
  float neb = fbm(dir.xy * 3.0 + dir.z * 1.7);
  col += vec3(0.09, 0.10, 0.15) * neb * neb * 0.9;
  return col;
}

// ---------- accretion disk ----------
vec3 diskColor(vec3 p, vec3 rayDir, float t) {
  float r = length(p.xz);
  float u = (r - DISK_IN) / (DISK_OUT - DISK_IN);

  // Keplerian angular velocity, inner edge orbits fastest
  float speed = 1.1 / pow(max(r, 0.6), 1.5);
  float ang = atan(p.z, p.x) + t * speed;

  // fine radial striations sheared by differential rotation.
  // The angular domain is mapped onto the unit circle so the noise is
  // periodic — sampling with the raw angle leaves a seam at the atan wrap.
  vec2 circ = vec2(cos(ang), sin(ang));
  float streak = fbm(vec2(circ.x * 2.0 + r * 0.35, circ.y * 2.0 + r * 2.4));
  float filaments = fbm(vec2(circ.x * 4.5 + r * 1.1, circ.y * 4.5 + r * 5.5) + 3.7);
  float density = streak * 0.75 + filaments * 0.5;
  density = pow(clamp(density, 0.0, 1.5), 1.9);

  // radial profile: dark gap at the inner rim, bright band, long decay
  float innerRise = smoothstep(0.0, 0.14, u);
  float band = exp(-u * 2.6) * 2.1 + exp(-u * 0.9) * 0.35;
  float outerFade = 1.0 - smoothstep(0.75, 1.0, u);
  float radial = innerRise * band * outerFade;

  // temperature: white-hot inner rim -> scarlet -> deep crimson
  vec3 hot = vec3(1.0, 0.92, 0.86);
  vec3 mid = vec3(1.0, 0.20, 0.10);
  vec3 cold = vec3(0.32, 0.03, 0.03);
  vec3 temp = mix(hot, mid, smoothstep(0.02, 0.3, u));
  temp = mix(temp, cold, smoothstep(0.3, 1.0, u));

  // Doppler beaming: side rotating toward the camera is boosted
  vec3 tangent = normalize(vec3(-p.z, 0.0, p.x));
  float dop = dot(tangent, -rayDir);
  float beaming = pow(clamp(1.0 + dop * 0.55, 0.2, 1.8), 2.0);

  // gravitational dimming near the hole
  float redshift = 1.0 / (1.0 + 0.8 / max(r - 1.6 * RS, 0.3));

  return temp * density * radial * beaming * redshift * 1.35;
}

void main() {
  vec2 frag = (gl_FragCoord.xy * 2.0 - u_res) / min(u_res.x, u_res.y);

  // on wide screens push the hole right-of-center so the headline breathes
  float aspect = u_res.x / u_res.y;
  frag.x -= 0.42 * smoothstep(1.1, 1.7, aspect);
  frag.y += 0.06 * smoothstep(1.1, 1.7, aspect);

  // camera: above the disk plane, slow orbit, mouse parallax
  float t = u_time * 0.10;
  float ca = cos(t * 0.5 + u_mouse.x * 0.25);
  float sa = sin(t * 0.5 + u_mouse.x * 0.25);
  float camDist = 12.0;
  float camHeight = 3.6 + u_mouse.y * 0.5;
  vec3 ro = vec3(camDist * sa, camHeight, -camDist * ca);
  vec3 target = vec3(0.0, 0.0, 0.0);

  vec3 fwd = normalize(target - ro);
  vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
  vec3 up = cross(right, fwd);
  float fov = 0.72;
  vec3 rd = normalize(fwd * fov + right * frag.x + up * frag.y);

  // specific angular momentum of the photon (conserved)
  vec3 h = cross(ro, rd);
  float h2 = dot(h, h);

  vec3 pos = ro;
  vec3 dir = rd;
  float prevY = pos.y;
  float minR2 = dot(pos, pos);
  vec3 col = vec3(0.0);
  bool captured = false;
  bool escaped = false;
  float diskAcc = 0.0;

  for (int i = 0; i < STEPS; i++) {
    float r2 = dot(pos, pos);

    if (r2 < RS * RS) { captured = true; break; }
    if (r2 > ESCAPE2) { escaped = true; break; }
    minR2 = min(minR2, r2);

    // adaptive step: very fine near the hole so capture actually happens
    float dt = 0.018 + 0.16 * smoothstep(1.2, 30.0, r2);
    vec3 next = pos + dir * dt;

    // disk plane crossing?
    if (prevY > 0.0 && next.y <= 0.0 || prevY < 0.0 && next.y >= 0.0) {
      float f = prevY / (prevY - next.y);
      vec3 hit = mix(pos, next, f);
      float rr = length(hit.xz);
      if (rr > DISK_IN && rr < DISK_OUT) {
        col += diskColor(hit, dir, u_time) * (1.0 - diskAcc * 0.8);
        diskAcc += 1.0;
        if (diskAcc > 2.5) { break; }
      }
    }

    // geodesic bend
    vec3 acc = -1.5 * h2 * pos / pow(r2, 2.5);
    dir = normalize(dir + acc * dt);
    prevY = pos.y;
    pos = next;
  }

  // photons that dove inside ~1.7 RS and never escaped are effectively lost
  // to the shadow even if the integrator let them slip back out
  bool shadowed = captured || (!escaped && sqrt(minR2) < 1.7 * RS);

  if (!shadowed) {
    vec3 sky = skyColor(dir);
    col += diskAcc < 0.5 ? sky : sky * 0.25;
  }

  // photon-ring glow hugging the shadow edge — only for near-miss rays;
  // captured photons must leave the shadow pure black
  float minR = sqrt(minR2);
  float glowGate = smoothstep(1.35 * RS, 1.75 * RS, minR);
  float ring = exp(-abs(minR - 1.9 * RS) * 5.5) * glowGate;
  col += vec3(1.0, 0.32, 0.18) * ring * 0.55;
  float halo = exp(-max(minR - 1.9 * RS, 0.0) * 1.1) * 0.16 * glowGate;
  col += vec3(1.0, 0.38, 0.22) * halo;

  // tonemap + vignette + grain
  col = col / (1.0 + col);
  col = pow(col, vec3(0.85));

  vec2 vq = gl_FragCoord.xy / u_res;
  float vig = smoothstep(1.25, 0.35, length(vq - 0.5) * 1.6);
  col *= mix(0.72, 1.0, vig);

  col += (hash12(gl_FragCoord.xy + fract(u_time) * 61.7) - 0.5) * 0.015;

  gl_FragColor = vec4(col, 1.0);
}
`
