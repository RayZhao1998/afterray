const canvas = document.querySelector("#shader");
const status = document.querySelector("#status");
const toggle = document.querySelector("#toggle");
const toggleLabel = toggle.querySelector(".toggle-label");

const controls = {
  gravity: bindRange("gravity"),
  glow: bindRange("glow"),
  speed: bindRange("speed"),
  particles: bindRange("particles"),
};

const gl = canvas.getContext("webgl2", {
  alpha: false,
  antialias: false,
  depth: false,
  powerPreference: "high-performance",
  preserveDrawingBuffer: false,
});

if (!gl) {
  status.textContent = "WebGL 2 is required for this study.";
  throw new Error("WebGL 2 is not available");
}

const vertexShader = `#version 300 es
precision highp float;

const vec2 POSITIONS[3] = vec2[3](
  vec2(-1.0, -1.0),
  vec2( 3.0, -1.0),
  vec2(-1.0,  3.0)
);

void main() {
  gl_Position = vec4(POSITIONS[gl_VertexID], 0.0, 1.0);
}
`;

const fragmentShader = `#version 300 es
precision highp float;

out vec4 outColor;

uniform vec2 uResolution;
uniform vec2 uPointer;
uniform float uTime;
uniform float uGravity;
uniform float uGlow;
uniform float uParticles;

#define PI 3.141592653589793
#define TAU 6.283185307179586

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
    mix(hash12(i + vec2(0.0, 1.0)), hash12(i + 1.0), f.x),
    f.y
  );
}

float fbm(vec2 p) {
  float value = 0.0;
  float amplitude = 0.5;
  for (int i = 0; i < 4; i++) {
    value += amplitude * noise(p);
    p = mat2(1.72, 1.08, -1.08, 1.72) * p + 8.31;
    amplitude *= 0.5;
  }
  return value;
}

float lineMask(float distanceToLine, float width) {
  return exp(-pow(abs(distanceToLine) / max(width, 0.0001), 1.42));
}

float angleDelta(float a, float b) {
  return atan(sin(a - b), cos(a - b));
}

// Hundreds of apparent particles are synthesized from a handful of polar grids.
// Inner orbits advance faster, approximating the velocity gradient in an accretion flow.
vec2 orbitalParticles(vec2 p, float time, float density) {
  float r = length(p);
  float angle = atan(p.y, p.x);
  float dust = 0.0;
  float hot = 0.0;

  for (int i = 0; i < 7; i++) {
    float fi = float(i);
    float orbitRadius = 0.345 + fi * 0.052;
    float count = 46.0 + fi * 11.0;
    float omega = 0.22 / pow(orbitRadius, 1.35);
    float movingGrid = (angle / TAU - time * omega) * count;
    float cell = floor(movingGrid);
    float seed = hash12(vec2(cell + fi * 47.0, fi * 19.7));
    float center = 0.18 + 0.64 * hash12(vec2(cell * 1.37, fi + 8.2));
    float tangent = (fract(movingGrid) - center) * TAU * orbitRadius / count;
    float jitter = (hash12(vec2(cell + 91.3, fi * 7.4)) - 0.5) * (0.017 + fi * 0.002);
    float radial = r - orbitRadius - jitter;
    float size = mix(0.0018, 0.0042, hash12(vec2(cell * 2.1, fi * 31.0)));
    float active = smoothstep(0.995 - min(density, 1.0) * 0.875, 1.0, seed);
    active += max(density - 1.0, 0.0) * 0.65;

    float d = length(vec2(radial, tangent * 1.35)) / size;
    float spark = exp(-d * d * 1.7) * active;
    float shortTrail = exp(-abs(radial) / (size * 0.72));
    shortTrail *= exp(-max(tangent, 0.0) / (size * 4.8));
    shortTrail *= smoothstep(-size * 9.0, 0.0, tangent) * active * 0.10;

    dust += spark + shortTrail;
    hot += spark * pow(seed, 5.0) * (1.25 - fi * 0.075);
  }

  float orbitalEnvelope = smoothstep(0.31, 0.35, r) * (1.0 - smoothstep(0.70, 0.78, r));
  return vec2(dust, hot) * orbitalEnvelope;
}

// Artistic memory motes inside the shadow. They are intentionally not presented
// as matter escaping the event horizon; their dim spiral is a product metaphor.
vec2 memoryParticles(vec2 p, float time, float density) {
  float r = length(p);
  float angle = atan(p.y, p.x);
  float motes = 0.0;
  float glints = 0.0;

  for (int i = 0; i < 5; i++) {
    float fi = float(i);
    float orbitRadius = 0.055 + fi * 0.043;
    float count = 16.0 + fi * 7.0;
    float omega = 0.34 / pow(orbitRadius + 0.12, 1.18);
    float spiral = time * 0.015 + 0.012 * sin(time * 0.7 + fi * 2.3);
    float movingGrid = (angle / TAU - time * omega) * count;
    float cell = floor(movingGrid);
    float seed = hash12(vec2(cell + fi * 29.0, fi * 13.7));
    float center = 0.2 + 0.6 * hash12(vec2(cell * 1.91, fi + 4.0));
    float tangent = (fract(movingGrid) - center) * TAU * orbitRadius / count;
    float radialJitter = (hash12(vec2(cell + 55.0, fi * 5.0)) - 0.5) * 0.019;
    float radial = r - max(orbitRadius - spiral * (0.15 + fi * 0.04), 0.022) - radialJitter;
    float size = mix(0.0014, 0.0034, seed);
    float active = smoothstep(0.995 - min(density, 1.0) * 0.755, 1.0, seed);
    active += max(density - 1.0, 0.0) * 0.40;
    float d = length(vec2(radial, tangent * 1.25)) / size;
    float mote = exp(-d * d * 1.8) * active;
    motes += mote;
    glints += mote * pow(seed, 7.0);
  }

  float inside = 1.0 - smoothstep(0.245, 0.275, r);
  return vec2(motes, glints) * inside;
}

float orbitingArc(
  vec2 p,
  float baseRadius,
  float head,
  float width,
  float arcLength,
  float phase
) {
  float r = length(p);
  float angle = atan(p.y, p.x);
  float warpedRadius = baseRadius + 0.014 * sin(angle * 3.0 + phase);
  float radial = exp(-pow((r - warpedRadius) / width, 2.0));
  float angular = exp(-pow(abs(angleDelta(angle, head)) / arcLength, 4.0));
  float filament = 0.72 + 0.28 * sin(angle * 38.0 - phase * 3.0);
  return radial * angular * filament;
}

vec3 redRamp(float energy) {
  vec3 ember = vec3(0.16, 0.004, 0.008);
  vec3 scarlet = vec3(1.00, 0.055, 0.035);
  vec3 hot = vec3(1.35, 0.72, 0.58);
  vec3 c = mix(ember, scarlet, smoothstep(0.04, 0.58, energy));
  return mix(c, hot, smoothstep(0.62, 1.15, energy));
}

void main() {
  vec2 frag = gl_FragCoord.xy;
  vec2 p = (2.0 * frag - uResolution.xy) / min(uResolution.x, uResolution.y);

  // Optical centering leaves room for the title without making the mark feel off-axis.
  p -= vec2(0.13, 0.015);
  p -= (uPointer - 0.5) * vec2(0.025, 0.018);

  float t = uTime;
  float r = length(p);
  float angle = atan(p.y, p.x);

  const float horizon = 0.285;
  float photonRadius = horizon + 0.024;

  // Inverse point-lens mapping. A straight source line becomes two curved images
  // around the event horizon. The clamp keeps the singularity numerically stable.
  float lensRadius = max(r, horizon * 0.72);
  float einstein = mix(0.105, 0.19, uGravity);
  vec2 source = p * (1.0 - (einstein * einstein) / (lensRadius * lensRadius));

  vec2 rayDirection = normalize(vec2(1.0, 0.72));
  vec2 rayNormal = vec2(-rayDirection.y, rayDirection.x);
  float alongRay = dot(source, rayDirection);
  float acrossRay = dot(source, rayNormal) - 0.012;

  float travelling = 0.78 + 0.22 * sin(alongRay * 14.0 - t * 2.4);
  float filamentNoise = 0.82 + 0.18 * fbm(vec2(alongRay * 7.0 - t * 0.24, acrossRay * 62.0));
  float coreRay = lineMask(acrossRay, 0.0045) * travelling;
  float rayGlow = lineMask(acrossRay, 0.032 + 0.010 * uGlow) * filamentNoise;

  // A tilted accretion sheet. Its far side is lifted above and below the shadow,
  // producing the recognizable gravitationally-lensed "over the top" silhouette.
  vec2 diskDirection = rayDirection;
  vec2 diskNormal = rayNormal;
  float diskX = dot(source, diskDirection);
  float diskY = dot(source, diskNormal);
  float diskSpan = 1.0 - smoothstep(0.23, 1.15, abs(diskX));
  float diskTexture = 0.58 + 0.42 * fbm(vec2(diskX * 18.0 - t * 0.55, diskY * 90.0));
  float diskCore = lineMask(diskY, 0.009) * diskSpan * diskTexture;
  float diskHaze = lineMask(diskY, 0.058) * diskSpan * (0.55 + 0.45 * diskTexture);

  // The circular photon ring remains analytically circular and cannot develop a seam.
  float ringDistance = abs(r - photonRadius);
  float beaming = 0.58 + 0.42 * smoothstep(-0.9, 0.75, dot(normalize(p + 0.0001), rayDirection));
  float ringCore = exp(-ringDistance * 390.0) * beaming;
  float ringGlow = exp(-ringDistance * (52.0 - 18.0 * uGlow)) * beaming;

  // Extra lensed arcs make the far side of the disk appear over and under the hole.
  float upperArc = exp(-pow((r - photonRadius - 0.040 - 0.018 * cos(angle * 2.0)) / 0.024, 2.0));
  upperArc *= smoothstep(-0.42, 0.3, p.y) * (1.0 - smoothstep(0.25, 0.82, abs(angle - 1.18)));
  float lowerArc = exp(-pow((r - photonRadius - 0.030) / 0.019, 2.0));
  lowerArc *= (1.0 - smoothstep(-0.42, 0.06, p.y)) * (1.0 - smoothstep(0.05, 1.0, abs(angle + 1.92)));

  float turbulence = fbm(vec2(angle * 3.1 - t * 0.13, r * 16.0 + t * 0.08));
  float corona = exp(-max(r - horizon, 0.0) * (9.2 - 2.4 * uGlow));
  corona *= (0.23 + 0.22 * turbulence) * (1.0 - smoothstep(horizon, 0.88, r));

  vec2 orbitDust = orbitalParticles(p, t, uParticles);
  vec2 memoryDust = memoryParticles(p, t, uParticles);

  // Three offset filaments orbit at different radii and angular velocities.
  float arcOne = orbitingArc(p, 0.372, t * 0.72 + 0.35, 0.0048, 0.88, t * 0.22);
  float arcTwo = orbitingArc(p, 0.438, -t * 0.43 - 1.5, 0.0034, 0.67, 2.2 - t * 0.17);
  float arcThree = orbitingArc(p, 0.535, t * 0.27 + 2.65, 0.0027, 0.48, 4.7 + t * 0.11);
  float orbitingLight = (arcOne * 0.48 + arcTwo * 0.31 + arcThree * 0.18) * uParticles;

  vec3 background = vec3(0.0045, 0.004, 0.007);
  float vignette = 1.0 - smoothstep(0.32, 1.52, length(p * vec2(0.82, 1.0)));
  background *= 0.52 + 0.48 * vignette;
  background += vec3(0.020, 0.007, 0.011) * exp(-r * 1.8);

  float stars = step(0.9982, hash12(floor((p + 2.0) * 230.0)));
  stars *= 0.12 + 0.22 * hash12(floor(p * 171.0));
  background += stars * vec3(0.48, 0.38, 0.40) * smoothstep(0.36, 0.82, r);

  float energy =
    diskCore * 0.92 +
    diskHaze * 0.28 * uGlow +
    coreRay * 0.62 +
    rayGlow * 0.18 * uGlow +
    ringCore * 1.35 +
    ringGlow * 0.31 * uGlow +
    upperArc * 0.24 +
    lowerArc * 0.16 +
    corona * uGlow +
    orbitDust.x * 0.18 * uParticles +
    orbitDust.y * 0.72 * uParticles +
    orbitingLight;

  vec3 color = background + redRamp(energy) * energy;

  // Slight warm/cool split in the deepest glow, while red remains the dominant hue.
  color += vec3(0.025, 0.008, 0.015) * rayGlow;
  color += vec3(0.002, 0.010, 0.017) * ringGlow * (1.0 - beaming) * 0.5;

  // The shadow is applied last, so no noisy light leaks into the black-hole core.
  float shadow = 1.0 - smoothstep(horizon - 0.0025, horizon + 0.0025, r);
  color = mix(color, vec3(0.0003, 0.00025, 0.0005), shadow);

  // Memory particles are added after the physical shadow pass by design. Their
  // low red values keep the core perceptually black while making motion legible.
  color += vec3(0.070, 0.006, 0.011) * memoryDust.x * uParticles;
  color += vec3(0.48, 0.055, 0.045) * memoryDust.y * uParticles;

  // ACES-inspired compression keeps the white-hot regions from clipping flat.
  color = color * (2.51 * color + 0.03) / (color * (2.43 * color + 0.59) + 0.14);
  color = pow(max(color, 0.0), vec3(0.94));

  float pixelGrain = hash12(frag + fract(t) * 91.7) - 0.5;
  color += pixelGrain * 0.012;
  outColor = vec4(color, 1.0);
}
`;

const program = createProgram(vertexShader, fragmentShader);
const uniforms = {
  resolution: gl.getUniformLocation(program, "uResolution"),
  pointer: gl.getUniformLocation(program, "uPointer"),
  time: gl.getUniformLocation(program, "uTime"),
  gravity: gl.getUniformLocation(program, "uGravity"),
  glow: gl.getUniformLocation(program, "uGlow"),
  particles: gl.getUniformLocation(program, "uParticles"),
};

const vertexArray = gl.createVertexArray();
gl.bindVertexArray(vertexArray);
gl.useProgram(program);

const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let paused = prefersReducedMotion.matches;
let elapsed = 0;
let previousFrame = performance.now();
let animationFrame = 0;
let pointerTarget = { x: 0.5, y: 0.5 };
let pointer = { ...pointerTarget };

setPaused(paused);
resize();
render(previousFrame);

const resizeObserver = new ResizeObserver(resize);
resizeObserver.observe(canvas);

canvas.addEventListener("pointermove", (event) => {
  const bounds = canvas.getBoundingClientRect();
  pointerTarget.x = event.clientX / bounds.width;
  pointerTarget.y = 1 - event.clientY / bounds.height;
});

canvas.addEventListener("pointerleave", () => {
  pointerTarget = { x: 0.5, y: 0.5 };
});

toggle.addEventListener("click", () => setPaused(!paused));

prefersReducedMotion.addEventListener("change", (event) => {
  if (event.matches) setPaused(true);
});

canvas.addEventListener("webglcontextlost", (event) => {
  event.preventDefault();
  cancelAnimationFrame(animationFrame);
  status.textContent = "Graphics context paused. Reload to restore.";
});

function bindRange(id) {
  const input = document.querySelector(`#${id}`);
  const output = document.querySelector(`#${id}-value`);
  input.addEventListener("input", () => {
    output.value = Number(input.value).toFixed(2);
  });
  return input;
}

function createShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const message = gl.getShaderInfoLog(shader) || "Unknown shader compilation error";
    gl.deleteShader(shader);
    status.textContent = message;
    throw new Error(message);
  }
  return shader;
}

function createProgram(vertexSource, fragmentSource) {
  const program = gl.createProgram();
  const vertex = createShader(gl.VERTEX_SHADER, vertexSource);
  const fragment = createShader(gl.FRAGMENT_SHADER, fragmentSource);
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  gl.deleteShader(vertex);
  gl.deleteShader(fragment);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const message = gl.getProgramInfoLog(program) || "Unknown shader link error";
    gl.deleteProgram(program);
    status.textContent = message;
    throw new Error(message);
  }
  return program;
}

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const width = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const height = Math.max(1, Math.round(canvas.clientHeight * dpr));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
  }
}

function setPaused(nextPaused) {
  paused = nextPaused;
  toggle.setAttribute("aria-pressed", String(paused));
  toggleLabel.textContent = paused ? "Play" : "Pause";
  previousFrame = performance.now();
}

function render(now) {
  resize();
  const delta = Math.min((now - previousFrame) / 1000, 0.05);
  previousFrame = now;
  if (!paused) elapsed += delta * Number(controls.speed.value);

  pointer.x += (pointerTarget.x - pointer.x) * 0.045;
  pointer.y += (pointerTarget.y - pointer.y) * 0.045;

  gl.uniform2f(uniforms.resolution, canvas.width, canvas.height);
  gl.uniform2f(uniforms.pointer, pointer.x, pointer.y);
  gl.uniform1f(uniforms.time, elapsed);
  gl.uniform1f(uniforms.gravity, Number(controls.gravity.value));
  gl.uniform1f(uniforms.glow, Number(controls.glow.value));
  gl.uniform1f(uniforms.particles, Number(controls.particles.value));
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  animationFrame = requestAnimationFrame(render);
}
