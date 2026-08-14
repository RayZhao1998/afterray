import { useEffect, useRef } from 'react'
import { fragmentShaderSource, vertexShaderSource } from './shaders'

function compile(gl: WebGLRenderingContext, type: number, src: string) {
  const sh = gl.createShader(type)!
  gl.shaderSource(sh, src)
  gl.compileShader(sh)
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) ?? 'shader compile failed')
  }
  return sh
}

/**
 * Full-bleed black hole renderer.
 * - WebGL1 fragment shader, fullscreen quad, no dependencies.
 * - Renders at a reduced internal resolution and upscales (the shader is
 *   the expensive part; upscaling is free).
 * - Pauses when offscreen, when the tab is hidden, and renders a single
 *   static frame under prefers-reduced-motion.
 */
export default function BlackHole({ className }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const gl = canvas.getContext('webgl', {
      antialias: false,
      depth: false,
      stencil: false,
      alpha: false,
      powerPreference: 'high-performance',
    })
    if (!gl) return

    let program: WebGLProgram
    try {
      program = gl.createProgram()!
      gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, vertexShaderSource))
      gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, fragmentShaderSource))
      gl.linkProgram(program)
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        throw new Error(gl.getProgramInfoLog(program) ?? 'link failed')
      }
    } catch {
      return
    }
    gl.useProgram(program)

    const buf = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buf)
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW)
    const loc = gl.getAttribLocation(program, 'a_pos')
    gl.enableVertexAttribArray(loc)
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0)

    const uRes = gl.getUniformLocation(program, 'u_res')
    const uTime = gl.getUniformLocation(program, 'u_time')
    const uMouse = gl.getUniformLocation(program, 'u_mouse')

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')

    let raf = 0
    let running = false
    let visible = true
    let start = performance.now()
    let pausedAt = 0
    const mouse = { x: 0, y: 0, tx: 0, ty: 0 }

    const resize = () => {
      // Internal render scale: the ray-march is fill-rate bound, so render
      // well below device pixels and let the GPU upscale.
      const scale = Math.min(window.devicePixelRatio || 1, 2) * 0.75
      const w = Math.max(2, Math.floor(canvas.clientWidth * scale))
      const h = Math.max(2, Math.floor(canvas.clientHeight * scale))
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w
        canvas.height = h
        gl.viewport(0, 0, w, h)
      }
    }

    const draw = (t: number) => {
      mouse.x += (mouse.tx - mouse.x) * 0.04
      mouse.y += (mouse.ty - mouse.y) * 0.04
      gl.uniform2f(uRes, canvas.width, canvas.height)
      gl.uniform1f(uTime, t)
      gl.uniform2f(uMouse, mouse.x, mouse.y)
      gl.drawArrays(gl.TRIANGLES, 0, 3)
    }

    const frame = (now: number) => {
      if (!running) return
      draw((now - start) / 1000)
      raf = requestAnimationFrame(frame)
    }

    const play = () => {
      if (running || !visible || reducedMotion.matches || document.hidden) return
      running = true
      start = performance.now() - pausedAt
      raf = requestAnimationFrame(frame)
    }
    const pause = () => {
      if (!running) return
      running = false
      pausedAt = performance.now() - start
      cancelAnimationFrame(raf)
    }

    const onMouse = (e: MouseEvent) => {
      mouse.tx = (e.clientX / window.innerWidth) * 2 - 1
      mouse.ty = -((e.clientY / window.innerHeight) * 2 - 1)
    }
    const io = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting
      if (visible) play()
      else pause()
    })
    io.observe(canvas)

    const onVis = () => (document.hidden ? pause() : play())
    document.addEventListener('visibilitychange', onVis)
    window.addEventListener('resize', resize)
    window.addEventListener('mousemove', onMouse)

    resize()
    if (reducedMotion.matches) {
      draw(12.0) // one static, well-composed frame
    } else {
      play()
    }

    return () => {
      pause()
      io.disconnect()
      document.removeEventListener('visibilitychange', onVis)
      window.removeEventListener('resize', resize)
      window.removeEventListener('mousemove', onMouse)
      gl.deleteProgram(program)
      gl.deleteBuffer(buf)
    }
  }, [])

  return <canvas ref={canvasRef} className={className} aria-hidden="true" />
}
