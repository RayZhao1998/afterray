const canvas = document.querySelector("#shader");
const status = document.querySelector("#status");
const toggle = document.querySelector("#toggle");
const toggleLabel = toggle.querySelector(".toggle-label");

const controls = {
  gravity: bindRange("gravity"),
  glow: bindRange("glow"),
  speed: bindRange("speed"),
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

#define PI 3.141592653589793

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
    corona * uGlow;

  vec3 color = background + redRamp(energy) * energy;

  // Slight warm/cool split in the deepest glow, while red remains the dominant hue.
  color += vec3(0.025, 0.008, 0.015) * rayGlow;
  color += vec3(0.002, 0.010, 0.017) * ringGlow * (1.0 - beaming) * 0.5;

  // The shadow is applied last, so no noisy light leaks into the black-hole core.
  float shadow = 1.0 - smoothstep(horizon - 0.0025, horizon + 0.0025, r);
  color = mix(color, vec3(0.0003, 0.00025, 0.0005), shadow);

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
  gl.drawArrays(gl.TRIANGLES, 0, 3);

  animationFrame = requestAnimationFrame(render);
}
