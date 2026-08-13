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
precision highp int;

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
precision highp int;

out vec4 outColor;

uniform vec2 uResolution;
uniform vec2 uPointer;
uniform float uTime;
uniform float uGravity;
uniform float uGlow;
uniform float uParticles;

#define PI 3.141592653589793
#define TAU 6.283185307179586
#define MARCH_STEPS 68

float saturate(float value) {
  return clamp(value, 0.0, 1.0);
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p3) {
  p3 = fract(p3 * 0.1031);
  p3 += dot(p3, p3.zyx + 31.32);
  return fract((p3.x + p3.y) * p3.z);
}

float noise3(vec3 p) {
  vec3 cell = floor(p);
  vec3 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float n000 = hash13(cell);
  float n100 = hash13(cell + vec3(1.0, 0.0, 0.0));
  float n010 = hash13(cell + vec3(0.0, 1.0, 0.0));
  float n110 = hash13(cell + vec3(1.0, 1.0, 0.0));
  float n001 = hash13(cell + vec3(0.0, 0.0, 1.0));
  float n101 = hash13(cell + vec3(1.0, 0.0, 1.0));
  float n011 = hash13(cell + vec3(0.0, 1.0, 1.0));
  float n111 = hash13(cell + vec3(1.0));
  return mix(
    mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
    mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
    f.z
  );
}

float fbm3(vec3 p) {
  float value = 0.0;
  float amplitude = 0.5;
  for (int i = 0; i < 4; i++) {
    value += amplitude * noise3(p);
    p = p * 2.03 + vec3(7.1, 3.7, 5.9);
    amplitude *= 0.5;
  }
  return value;
}

mat2 rotation(float angle) {
  float c = cos(angle);
  float s = sin(angle);
  return mat2(c, -s, s, c);
}

vec3 worldToDisk(vec3 p) {
  p.yz = rotation(-0.22) * p.yz;
  p.xy = rotation(0.09) * p.xy;
  return p;
}

vec3 diskToWorld(vec3 p) {
  p.xy = rotation(-0.09) * p.xy;
  p.yz = rotation(0.22) * p.yz;
  return p;
}

float angleDelta(float a, float b) {
  return atan(sin(a - b), cos(a - b));
}

float annulus(float radius, float innerRadius, float outerRadius, float feather) {
  return smoothstep(innerRadius, innerRadius + feather, radius) *
    (1.0 - smoothstep(outerRadius - feather, outerRadius, radius));
}

float starLayer(vec3 direction, float scale, float threshold) {
  vec3 grid = direction * scale;
  vec3 cell = floor(grid);
  vec3 local = fract(grid) - 0.5;
  float seed = hash13(cell);
  vec3 offset = vec3(
    hash13(cell + 3.7),
    hash13(cell + 17.1),
    hash13(cell + 29.4)
  ) - 0.5;
  float point = exp(-dot(local - offset * 0.62, local - offset * 0.62) * 115.0);
  float star = smoothstep(threshold, 1.0, seed) * point;
  float twinkle = 0.72 + 0.28 * sin(uTime * (1.2 + seed * 2.0) + seed * 37.0);
  return star * twinkle;
}

vec3 backgroundSpace(vec3 direction) {
  vec3 color = vec3(0.0022, 0.0020, 0.0042);
  float stars = starLayer(direction, 210.0, 0.985);
  stars += starLayer(direction.yzx, 410.0, 0.993) * 0.52;
  color += vec3(0.56, 0.42, 0.38) * stars;
  float nebula = fbm3(direction * 3.8 + vec3(1.0, 7.0, 3.0));
  color += vec3(0.012, 0.0025, 0.0055) * pow(nebula, 3.0);
  return color;
}

vec3 emissionRamp(float heat) {
  vec3 deep = vec3(0.038, 0.0015, 0.0025);
  vec3 red = vec3(0.62, 0.018, 0.007);
  vec3 coral = vec3(1.04, 0.18, 0.052);
  vec3 whiteHot = vec3(1.70, 1.05, 0.61);
  vec3 color = mix(deep, red, smoothstep(0.02, 0.36, heat));
  color = mix(color, coral, smoothstep(0.30, 0.82, heat));
  return mix(color, whiteHot, smoothstep(0.82, 1.7, heat));
}

float particleField(vec3 diskPosition, float radius, float angle, float time) {
  float orbitalSpeed = 0.42 / pow(max(radius, 0.48), 1.42);
  float angularCount = mix(165.0, 76.0, saturate((radius - 0.50) / 1.18));
  vec2 particleCoordinates = vec2(
    (angle / TAU - time * orbitalSpeed) * angularCount,
    (radius - 0.48) * 25.0
  );
  vec2 particleCell = floor(particleCoordinates);
  vec2 particleLocal = fract(particleCoordinates) - 0.5;
  float seed = hash12(particleCell + 17.3);
  particleLocal.x -= (seed - 0.5) * 0.54;
  particleLocal.y -= (hash12(particleCell + 41.7) - 0.5) * 0.48;
  float activation = smoothstep(0.955 - min(uParticles, 1.0) * 0.055, 1.0, seed);
  activation += max(uParticles - 1.0, 0.0) * 0.16;
  float pointDistance = length(particleLocal * vec2(0.62, 1.0));
  float verticalDistance = abs(diskPosition.y) / 0.024;
  float point = exp(-pointDistance * pointDistance * 92.0 - verticalDistance * verticalDistance * 2.8);
  float trail = exp(-abs(particleLocal.y) * 16.0 - max(particleLocal.x, 0.0) * 11.0);
  trail *= smoothstep(-0.38, 0.0, particleLocal.x) * 0.055;
  return (point + trail) * activation;
}

float filamentField(float radius, float angle, float time) {
  float filament = 0.0;
  float headOne = time * 0.63 + 0.4;
  float headTwo = -time * 0.39 - 1.7;
  float headThree = time * 0.24 + 2.6;

  float radialOne = exp(-pow((radius - 0.67) / 0.026, 2.0));
  float radialTwo = exp(-pow((radius - 0.96) / 0.032, 2.0));
  float radialThree = exp(-pow((radius - 1.27) / 0.038, 2.0));
  float gateOne = exp(-pow(abs(angleDelta(angle, headOne)) / 0.82, 4.0));
  float gateTwo = exp(-pow(abs(angleDelta(angle, headTwo)) / 0.66, 4.0));
  float gateThree = exp(-pow(abs(angleDelta(angle, headThree)) / 0.52, 4.0));

  filament += radialOne * gateOne * 0.72;
  filament += radialTwo * gateTwo * 0.43;
  filament += radialThree * gateThree * 0.26;
  return filament * uParticles;
}

vec2 diskVolume(vec3 worldPosition, vec3 rayDirection, float time) {
  vec3 diskPosition = worldToDisk(worldPosition);
  float radius = length(diskPosition.xz);
  float radialMask = annulus(radius, 0.49, 1.72, 0.09);
  float thickness = mix(0.038, 0.064, saturate((radius - 0.49) / 1.23));
  float verticalMask = exp(-pow(abs(diskPosition.y) / thickness, 2.0));

  // Keep the expensive procedural fields local to the visible disk volume.
  if (radialMask * verticalMask < 0.001) {
    return vec2(0.0);
  }

  float angle = atan(diskPosition.z, diskPosition.x);
  float spiralNoise = fbm3(vec3(
    angle * 4.1 - time * 0.48 / pow(max(radius, 0.5), 1.15),
    radius * 8.0,
    diskPosition.y * 28.0
  ));
  float bands = 0.50 + 0.50 * sin(radius * 46.0 - angle * 3.0 + spiralNoise * 3.2);
  bands = mix(0.78, 1.0, smoothstep(0.08, 0.92, bands));

  vec3 tangentDisk = normalize(vec3(-diskPosition.z, 0.0, diskPosition.x));
  vec3 tangentWorld = normalize(diskToWorld(tangentDisk));
  float approach = dot(tangentWorld, -rayDirection);
  float doppler = pow(max(0.82, 1.0 + approach * 0.14), 1.40);
  float radialHeat = mix(1.12, 0.18, saturate((radius - 0.49) / 1.23));

  float baseDensity = radialMask * verticalMask * bands;
  float particles = particleField(diskPosition, radius, angle, time) * radialMask;
  float filaments = filamentField(radius, angle, time) * verticalMask;
  float density = baseDensity * 0.68 + particles * 0.58 + filaments * 0.52;
  float heat = (baseDensity * radialHeat + particles * 0.64 + filaments * 0.68) * doppler;
  return vec2(density, heat);
}

float orbitalDustLayer(vec2 diskScreen, float time, float angularScale, float radialScale, float salt) {
  vec2 diskPlane = vec2(diskScreen.x, diskScreen.y * 6.2);
  float radius = length(diskPlane);
  float angle = atan(diskPlane.y, diskPlane.x);
  float orbitalSpeed = 0.17 / pow(max(radius, 0.30), 1.35);
  vec2 coordinates = vec2(
    angle / TAU * angularScale - time * orbitalSpeed * angularScale,
    radius * radialScale
  );
  vec2 cell = floor(coordinates);
  vec2 local = fract(coordinates) - 0.5;
  float seed = hash12(cell + salt);
  vec2 offset = vec2(hash12(cell + salt + 13.2), hash12(cell + salt + 47.8)) - 0.5;
  local -= offset * vec2(0.72, 0.66);
  float activation = smoothstep(0.974 - min(uParticles, 1.0) * 0.050, 1.0, seed);
  activation += max(uParticles - 1.0, 0.0) * 0.11;
  float point = exp(-dot(local * vec2(0.58, 1.0), local * vec2(0.58, 1.0)) * 145.0);
  float trail = exp(-abs(local.y) * 28.0 - abs(local.x + 0.12) * 7.0) * 0.085;
  float diskGate = annulus(radius, 0.31, 1.45, 0.10);
  return (point + trail) * activation * diskGate;
}

vec2 orbitalDust(vec2 diskScreen, float time) {
  float fine = orbitalDustLayer(diskScreen, time, 143.0, 38.0, 11.0);
  float near = orbitalDustLayer(diskScreen, time * 0.83, 91.0, 27.0, 73.0);
  return vec2(fine + near * 0.72, near);
}

void cameraRay(vec2 uv, out vec3 rayOrigin, out vec3 rayDirection) {
  vec2 pointer = (uPointer - 0.5) * vec2(0.26, 0.16);
  rayOrigin = vec3(0.10 + pointer.x, 0.42 + pointer.y, 3.55);
  vec3 target = vec3(0.08, 0.0, 0.0);
  vec3 forward = normalize(target - rayOrigin);
  vec3 cameraRight = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
  vec3 cameraUp = normalize(cross(cameraRight, forward));

  float roll = -0.12;
  vec3 rolledRight = cameraRight * cos(roll) + cameraUp * sin(roll);
  vec3 rolledUp = -cameraRight * sin(roll) + cameraUp * cos(roll);
  rayDirection = normalize(forward * 1.82 + uv.x * rolledRight + uv.y * rolledUp);
}

void main() {
  vec2 fragment = gl_FragCoord.xy;
  vec2 uv = (2.0 * fragment - uResolution.xy) / uResolution.y;

  vec3 rayOrigin;
  vec3 initialDirection;
  cameraRay(uv, rayOrigin, initialDirection);

  vec3 rayPosition = rayOrigin;
  vec3 rayDirection = initialDirection;
  vec3 accumulated = vec3(0.0);
  float transmittance = 1.0;
  float minimumRadius = 99.0;
  bool swallowed = false;

  const float eventHorizon = 0.405;
  const float photonShell = 0.535;

  for (int i = 0; i < MARCH_STEPS; i++) {
    float radius = length(rayPosition);
    minimumRadius = min(minimumRadius, radius);

    if (radius < eventHorizon) {
      swallowed = true;
      break;
    }

    float proximity = 1.0 - smoothstep(0.48, 2.25, radius);
    float stepLength = mix(0.085, 0.024, proximity);

    vec2 volume = diskVolume(rayPosition, rayDirection, uTime);
    float corona = 0.0;
    if (radius < 1.48) {
      float coronaNoise = noise3(rayPosition * 7.3 + vec3(0.0, -uTime * 0.11, uTime * 0.07));
      float coronaEnvelope = exp(-pow((radius - 0.72) / 0.42, 2.0));
      corona = coronaEnvelope * pow(coronaNoise, 3.4) * 0.11 * uGlow;
    }

    float localDensity = volume.x * 0.72 + corona;
    float localHeat = volume.y + corona * 0.5;
    float opacity = 1.0 - exp(-localDensity * stepLength * 4.6);
    vec3 emission = emissionRamp(localHeat) * localHeat;
    accumulated += transmittance * emission * opacity * 0.82;
    transmittance *= 1.0 - opacity * 0.34;

    float gravityStrength = mix(0.032, 0.082, uGravity);
    vec3 acceleration = -rayPosition * gravityStrength / max(radius * radius * radius, 0.055);
    rayDirection = normalize(rayDirection + acceleration * stepLength);
    rayPosition += rayDirection * stepLength;

    if (length(rayPosition) > 6.3 || transmittance < 0.018) {
      break;
    }
  }

  vec3 color = accumulated;

  if (!swallowed) {
    vec3 bentBackground = backgroundSpace(rayDirection);
    color += bentBackground * transmittance;
  } else {
    color += vec3(0.00022, 0.00018, 0.00038) * transmittance;
  }

  // Physically bent rays provide the base. This near-camera projection gives
  // the lensed rear disk a clear silhouette at real-time sampling rates.
  // Match the near-camera reconstruction to the actual rolled 3D disk.
  // The previous sign was inverted, producing a false crossing band.
  vec2 diskScreen = rotation(0.12) * uv;
  float screenRadius = length(uv);
  float screenHorizon = 1.0 - smoothstep(0.292, 0.314, screenRadius);
  float frontSlice = exp(-pow(diskScreen.y / 0.052, 2.0));
  frontSlice *= smoothstep(0.055, 0.27, screenRadius);
  float shadow = screenHorizon * (1.0 - frontSlice * 0.88);
  color *= 1.0 - shadow * 0.985;

  float arcDomain = saturate(1.0 - pow(diskScreen.x / 0.34, 2.0));
  float arcHeight = 0.305 * sqrt(arcDomain);
  float arcGate = 1.0 - smoothstep(0.31, 0.355, abs(diskScreen.x));
  float upperArc = exp(-pow((diskScreen.y - arcHeight) / 0.037, 2.0)) * arcGate;
  float upperArcCore = exp(-pow((diskScreen.y - arcHeight) / 0.0085, 2.0)) * arcGate;
  float lowerArc = exp(-pow((diskScreen.y + arcHeight) / 0.039, 2.0)) * arcGate;
  float lowerArcCore = exp(-pow((diskScreen.y + arcHeight) / 0.010, 2.0)) * arcGate;
  float arcNoise = noise3(vec3(
    diskScreen.x * 24.0 - uTime * 0.20,
    diskScreen.y * 18.0,
    4.7
  ));
  float arcFlow = 0.48 + 0.52 * smoothstep(0.18, 0.90, arcNoise);
  color += vec3(1.02, 0.24, 0.055) * upperArc * arcFlow * 0.40 * uGlow;
  color += vec3(1.68, 0.94, 0.50) * upperArcCore * (0.72 + arcNoise * 0.28) * 0.22 * uGlow;
  color += vec3(0.82, 0.105, 0.022) * lowerArc * arcFlow * 0.22 * uGlow;
  color += vec3(1.24, 0.44, 0.12) * lowerArcCore * arcFlow * 0.10 * uGlow;

  float upperBloom = exp(-pow((diskScreen.y - arcHeight) / 0.070, 2.0)) * arcGate;
  upperBloom *= smoothstep(-0.05, 0.16, diskScreen.y);
  color += vec3(0.42, 0.026, 0.007) * upperBloom * 0.20 * uGlow;

  float lowerBloom = exp(-pow((diskScreen.y + arcHeight) / 0.078, 2.0)) * arcGate;
  lowerBloom *= 1.0 - smoothstep(-0.16, 0.02, diskScreen.y);
  color += vec3(0.22, 0.006, 0.004) * lowerBloom * 0.11 * uGlow;

  float foregroundBand = exp(-pow(diskScreen.y / 0.048, 2.0));
  foregroundBand *= 1.0 - smoothstep(1.16, 1.46, abs(diskScreen.x));
  float foregroundTexture = 0.42 + 0.58 * noise3(vec3(
    diskScreen.x * 6.0 - uTime * 0.22,
    diskScreen.y * 31.0,
    9.3
  ));
  float foregroundHeat = 1.0 - smoothstep(0.12, 1.15, abs(diskScreen.x));
  color += mix(vec3(0.42, 0.007, 0.003), vec3(1.46, 0.64, 0.25), foregroundHeat) *
    foregroundBand * foregroundTexture * 0.66;

  float foregroundCore = exp(-pow(diskScreen.y / 0.0075, 2.0));
  foregroundCore *= 1.0 - smoothstep(0.92, 1.24, abs(diskScreen.x));
  color += mix(vec3(0.54, 0.018, 0.006), vec3(1.72, 1.02, 0.58), foregroundHeat) *
    foregroundCore * foregroundTexture * 0.15;

  float outerDiskGate = smoothstep(0.27, 0.40, abs(diskScreen.x));
  outerDiskGate *= 1.0 - smoothstep(1.15, 1.52, abs(diskScreen.x));
  float directHalo = exp(-pow(diskScreen.y / 0.100, 2.0)) * outerDiskGate;
  float haloTexture = 0.34 + 0.66 * noise3(vec3(
    diskScreen.x * 7.0 - uTime * 0.08,
    diskScreen.y * 20.0,
    12.1
  ));
  color += vec3(0.30, 0.007, 0.003) * directHalo * haloTexture * 0.22;

  vec2 dust = orbitalDust(diskScreen, uTime);
  float dustVisibility = 1.0 - screenHorizon * (1.0 - frontSlice * 0.92);
  float approachingSide = mix(0.72, 1.0, smoothstep(-0.75, 0.58, diskScreen.x));
  color += mix(vec3(0.78, 0.035, 0.012), vec3(1.34, 0.58, 0.25), dust.y) *
    dust.x * dustVisibility * approachingSide * 0.82;

  // Rays grazing the photon shell generate several progressively finer images.
  float photonDistance = abs(minimumRadius - photonShell);
  float primaryRing = exp(-photonDistance * 78.0);
  float secondaryRing = exp(-abs(minimumRadius - photonShell * 0.965) * 185.0) * 0.35;
  float beaming = 0.62 + 0.38 * saturate(dot(rayDirection, normalize(vec3(0.82, 0.10, -0.38))));
  float projectedPhoton = exp(-abs(screenRadius - 0.314) * 148.0);
  float secondaryPhoton = exp(-abs(screenRadius - 0.302) * 265.0);
  float tertiaryPhoton = exp(-abs(screenRadius - 0.296) * 440.0);
  float photonGate = 0.05 + 0.95 * smoothstep(-0.14, 0.25, diskScreen.y);
  color += emissionRamp(primaryRing) * (primaryRing * 0.038 + secondaryRing * 0.024) * beaming * uGlow;
  color += vec3(1.48, 0.58, 0.20) * projectedPhoton * photonGate * 0.026 * uGlow;
  color += vec3(1.64, 0.78, 0.34) * secondaryPhoton * photonGate * 0.011 * uGlow;
  color += vec3(1.72, 0.98, 0.54) * tertiaryPhoton * photonGate * 0.004 * uGlow;

  float vignette = 1.0 - smoothstep(0.42, 1.55, length(uv * vec2(0.82, 1.0)));
  color *= 0.52 + 0.48 * vignette;

  color = color * (2.51 * color + 0.03) / (color * (2.43 * color + 0.59) + 0.14);
  color = pow(max(color, 0.0), vec3(0.93));

  float grain = hash12(fragment + fract(uTime) * 97.3) - 0.5;
  color += grain * 0.010;
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
  const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
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
