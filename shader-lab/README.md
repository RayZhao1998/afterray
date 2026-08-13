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

The renderer draws one full-screen triangle. The fragment shader performs an
inverse point-lens mapping on a diagonal source ray, then composes a perfectly
analytic photon ring, lensed disk arcs, a pure-black event-horizon shadow,
procedural grain, and restrained star dust.

## Controls

- **Gravity** changes the Einstein-radius approximation used by the inverse
  lens map.
- **Corona** changes the width and energy of the glow around the photon ring.
- **Drift** changes procedural disk motion; it does not rotate the entire mark.
- **Particles** changes the visibility and density of the orbital dust, light
  filaments, and the dim artistic "memory motes" inside the shadow.
- **Pause** freezes time. Motion is paused by default when the operating system
  requests reduced motion.

## Scientific versus artistic layers

The external motion follows a qualitative accretion-flow model: inner material
orbits faster, the approaching side is weighted brighter, the disk is lensed
above and below the shadow, and multiple increasingly faint light structures
sit near the photon ring. The shader remains a real-time optical approximation,
not a general-relativistic ray tracer.

The event horizon cannot emit visible particles to an outside observer. The dim
particles drawn inside the shadow are therefore explicitly artistic: they
represent memories spiraling inward for the AfterRay brand, rather than physical
matter escaping a black hole.

## Integration

The canvas is independent of the surrounding page. To move it into a React or
Vite application, keep the shader source and WebGL setup in a component effect,
retain the `ResizeObserver` cleanup, and drive the three uniforms from component
state. No runtime package is required.
