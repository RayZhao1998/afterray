# AfterRay shader lab

A dependency-free WebGL 2 study of the original AfterRay direction: one red ray
travels from the lower left to the upper right and is gravitationally lensed
around a black hole.

The effect is inspired by the physical ideas associated with cinematic black
hole rendering—an event-horizon shadow, photon ring, Doppler-weighted light,
and an accretion sheet whose far side is lensed above and below the shadow. The
animation also contains procedural orbital dust and three rotating light
filaments. It does not reproduce a film frame or asset.

## Run

From the repository root:

```sh
python3 -m http.server 4173 --directory shader-lab
```

Open <http://localhost:4173>.

Opening `index.html` directly may work in some browsers, but a local server is
recommended because the JavaScript is loaded as an ES module.

## Structure

- `index.html` contains the semantic shell and shader controls.
- `styles.css` contains the presentation and responsive treatment.
- `app.js` contains the WebGL 2 setup and both GLSL shaders.

The renderer draws one full-screen triangle. For every fragment, the shader
constructs a perspective camera ray and bends it toward the black hole during
68 adaptive integration steps. Along that curved three-dimensional path it
integrates emission and opacity from a tilted, thick accretion volume, orbiting
particles, partial light filaments, and a diffuse corona.
The result has real perspective, front/back occlusion, and depth-dependent
motion instead of composing polar effects in screen space.

## Controls

- **Gravity** changes the strength of the curved camera-ray integration.
- **Corona** changes the width and energy of the glow around the photon ring.
- **Drift** changes procedural disk motion; it does not rotate the entire mark.
- **Particles** changes the visibility and density of the orbital dust and
  light filaments outside the shadow.
- **Pause** freezes time. Motion is paused by default when the operating system
  requests reduced motion.

## Scientific versus artistic layers

The external motion follows a qualitative accretion-flow model: inner material
orbits faster, the approaching side is weighted brighter, curved rays can see
the disk's far side above and below the shadow, and multiple increasingly faint
light structures sit near the photon shell. This is a three-dimensional real-
time optical approximation, not a solver for the full Kerr spacetime metric.

The event-horizon shadow remains unlit. Procedural particles are restricted to
the accretion flow outside it.

## Integration

The canvas is independent of the surrounding page. To move it into a React or
Vite application, keep the shader source and WebGL setup in a component effect,
retain the `ResizeObserver` cleanup, and drive the three uniforms from component
state. No runtime package is required.
