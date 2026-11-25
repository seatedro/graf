"use strict";

const SurveyWorld = (() => {
  const tileSize = 96, columns = 8, rows = 10;
  const cameraSize = 8;
  const corners = "vec2f(-1,-1), vec2f(1,-1), vec2f(-1,1), vec2f(-1,1), vec2f(1,-1), vec2f(1,1)";

  function sprites(palette) {
    const image = document.createElement("canvas");
    image.width = tileSize * columns;
    image.height = tileSize * rows;
    const c = image.getContext("2d", { willReadFrequently: true });
    for (let variant = 0; variant < 4; variant++) {
      for (const [index, hex] of palette.entries()) {
        const tile = variant * palette.length + index;
        const rgb = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
        const tone = (k, add = 0, a = 1) => "rgba(" + rgb.map(v => Math.min(255, Math.round(v * k + add))).join(",") + "," + a + ")";
        const light = variant % 2 === 1, planet = variant < 2;
        c.save();
        c.translate((tile % columns + .5) * tileSize, (Math.floor(tile / columns) + .5) * tileSize);
        const glow = c.createRadialGradient(0, 0, 4, 0, 0, 47);
        glow.addColorStop(0, tone(.9, 0, .82));
        glow.addColorStop(.31, tone(.9, 0, light ? .22 : .43));
        glow.addColorStop(.65, tone(.8, 0, light ? .06 : .12));
        glow.addColorStop(1, tone(.8, 0, 0));
        c.fillStyle = glow;
        c.fillRect(-48, -48, 96, 96);

        if (planet) {
          const surface = c.createRadialGradient(-6, -8, 0, 2, 4, 23);
          surface.addColorStop(0, tone(.86, light ? 28 : 84));
          surface.addColorStop(.42, tone(.98));
          surface.addColorStop(.72, tone(.65));
          surface.addColorStop(.92, tone(.23, 4));
          surface.addColorStop(1, tone(.48, 12));
          c.beginPath();
          c.arc(0, 0, 15.5, 0, 2 * Math.PI);
          c.fillStyle = surface;
          c.fill();
          c.lineWidth = 1;
          c.strokeStyle = tone(.9, 22, .72);
          c.stroke();
        } else {
          c.fillStyle = tone(light ? .55 : .88, light ? 0 : 24, .65);
          c.beginPath();
          c.moveTo(0, -32); c.lineTo(3, -4); c.lineTo(30, 0); c.lineTo(3, 4);
          c.lineTo(0, 32); c.lineTo(-3, 4); c.lineTo(-30, 0); c.lineTo(-3, -4);
          c.closePath(); c.fill();
          const core = c.createRadialGradient(-2, -3, 1, 0, 0, 14);
          core.addColorStop(0, light ? tone(.4) : "#fffdf0");
          core.addColorStop(.6, tone(light ? .65 : .97, light ? 0 : 18));
          core.addColorStop(1, tone(.85, 0, 0));
          c.fillStyle = core;
          c.fillRect(-14, -14, 28, 28);
        }
        c.restore();
      }
    }
    return image;
  }

  function radius(n, scale, focus) {
    return Math.min(23, Math.max(1.35, n.radius * Math.sqrt(scale))) * (n.index === focus ? 1.28 : 1);
  }

  const wgsl = `
    struct Camera { view: vec4f, lens: vec4f }
    @group(0) @binding(0) var<uniform> cam: Camera;
    @group(0) @binding(1) var atlas: texture_2d<f32>;
    @group(0) @binding(2) var atlasSampler: sampler;
    fn clip(p: vec2f) -> vec4f {
      return vec4f(p / cam.view.xy * vec2f(2,-2) + vec2f(-1,1), 0, 1);
    }
    struct Sprite { @builtin(position) p: vec4f, @location(0) uv: vec2f }
    @vertex fn node(@builtin(vertex_index) v: u32, @location(0) geometry: vec4f, @location(1) id: f32) -> Sprite {
      let corner = array<vec2f,6>(${corners})[v];
      let size = clamp(geometry.z * sqrt(cam.lens.x), 1.35, 23.0) * select(3.0, 3.84, id == cam.lens.z);
      let tile = u32(geometry.w + cam.lens.y);
      let origin = vec2f(f32(tile % ${columns}u), f32(tile / ${columns}u));
      return Sprite(clip(geometry.xy * cam.lens.x + cam.view.zw + corner * size),
        (origin + corner * 0.49 + 0.5) / vec2f(${columns},${rows}));
    }
    @fragment fn surface(v: Sprite) -> @location(0) vec4f {
      return textureSample(atlas, atlasSampler, v.uv);
    }
    struct Trail { @builtin(position) p: vec4f, @location(0) ink: vec4f }
    @vertex fn edge(@location(0) location: vec2f, @location(1) ids: vec2f, @location(2) level: f32) -> Trail {
      let selected = any(ids == vec2f(cam.lens.z));
      let amount = select(clamp(cam.lens.w * level, 0.0, 0.48), min(0.8, 0.1 + level * 0.55), selected);
      let ink = select(vec3f(0.48, 0.64, 0.68), vec3f(0.16, 0.30, 0.37), cam.lens.y > 0);
      return Trail(clip(location * cam.lens.x + cam.view.zw), vec4f(ink,amount));
    }
    @fragment fn filament(v: Trail) -> @location(0) vec4f { return v.ink; }
  `;

  async function webgpu(canvas, atlas, onLoss) {
    if (!navigator.gpu) return null;
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter || adapter.info?.isFallbackAdapter) return null;
    const device = await adapter.requestDevice();
    const format = navigator.gpu.getPreferredCanvasFormat();
    const blend = { color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha" }, alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" } };
    const shader = device.createShaderModule({ code: wgsl });
    const attrs = formats => {
      let offset = 0;
      return formats.map((format, shaderLocation) => {
        const attr = { format, shaderLocation, offset };
        offset += 4 * Number(format.split("x")[1] || 1);
        return attr;
      });
    };
    const pipeline = (vertex, fragment, topology, stepMode, formats) => device.createRenderPipelineAsync({
      layout: "auto", primitive: { topology },
      vertex: { module: shader, entryPoint: vertex, buffers: [{ arrayStride: 20, stepMode, attributes: attrs(formats) }] },
      fragment: { module: shader, entryPoint: fragment, targets: [{ format, blend }] },
    });
    const [dots, lines] = await Promise.all([
      pipeline("node", "surface", "triangle-list", "instance", ["float32x4", "float32"]),
      pipeline("edge", "filament", "line-list", "vertex", ["float32x2", "float32x2", "float32"]),
    ]);
    const uniform = device.createBuffer({ size: cameraSize * 4, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const texture = device.createTexture({ size: [atlas.width, atlas.height], format: "rgba8unorm",
      usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING });
    const pixels = atlas.getContext("2d").getImageData(0, 0, atlas.width, atlas.height);
    device.queue.writeTexture({ texture }, pixels.data, { bytesPerRow: atlas.width * 4 }, [atlas.width, atlas.height]);
    const entry = { binding: 0, resource: { buffer: uniform } };
    const dotsGroup = device.createBindGroup({ layout: dots.getBindGroupLayout(0), entries: [entry,
      { binding: 1, resource: texture.createView() }, { binding: 2, resource: device.createSampler({ minFilter: "linear", magFilter: "linear" }) }] });
    const linesGroup = device.createBindGroup({ layout: lines.getBindGroupLayout(0), entries: [entry] });
    const context = canvas.getContext("webgpu");
    if (!context) { device.destroy(); return null; }
    context.configure({ device, format, alphaMode: "premultiplied" });
    device.lost.then(onLoss);

    let buffers = [];
    return {
      name: "WebGPU",
      upload(arrays) {
        for (const b of buffers) b.destroy();
        buffers = arrays.map(data => {
          const buffer = device.createBuffer({ size: Math.max(20, data.byteLength), usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
          if (data.length) device.queue.writeBuffer(buffer, 0, data);
          return buffer;
        });
      },
      draw(camera, counts) {
        device.queue.writeBuffer(uniform, 0, camera);
        const encoder = device.createCommandEncoder();
        const pass = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(),
          loadOp: "clear", clearValue: { r: 0, g: 0, b: 0, a: 0 }, storeOp: "store" }] });
        if (counts[1]) {
          pass.setPipeline(lines); pass.setBindGroup(0, linesGroup);
          pass.setVertexBuffer(0, buffers[1]); pass.draw(counts[1]);
        }
        if (counts[0]) {
          pass.setPipeline(dots); pass.setBindGroup(0, dotsGroup);
          pass.setVertexBuffer(0, buffers[0]); pass.draw(6, counts[0]);
        }
        pass.end();
        device.queue.submit([encoder.finish()]);
      },
    };
  }

  function webgl(canvas, atlas, onLoss) {
    const gl = canvas.getContext("webgl2", { alpha: true, antialias: true, depth: false, stencil: false });
    if (!gl) return null;
    canvas.addEventListener("webglcontextlost", onLoss, { once: true });
    const header = "#version 300 es\nprecision highp float;\nuniform vec4 view,lens;\n";
    const clip = "vec4 clip(vec2 p){return vec4(p/view.xy*vec2(2,-2)+vec2(-1,1),0,1);}";
    const shader = (type, source) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, header + source); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    const program = (vertex, fragment) => {
      const p = gl.createProgram();
      for (const s of [shader(gl.VERTEX_SHADER, clip + vertex), shader(gl.FRAGMENT_SHADER, fragment)]) {
        gl.attachShader(p, s); gl.deleteShader(s);
      }
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      return { p, view: gl.getUniformLocation(p, "view"), lens: gl.getUniformLocation(p, "lens") };
    };
    const dot = program(`
      layout(location=0) in vec4 geom; layout(location=1) in float id; out vec2 uv;
      void main(){vec2 c=vec2[6](${corners.replaceAll("vec2f", "vec2")})[gl_VertexID];
        float r=clamp(geom.z*sqrt(lens.x),1.35,23.)*(id==lens.z?3.84:3.);
        int tile=int(geom.w+lens.y);
        uv=(vec2(tile%${columns},tile/${columns})+c*.49+.5)/vec2(${columns},${rows});
        gl_Position=clip(geom.xy*lens.x+view.zw+c*r);}`,
      "in vec2 uv; uniform sampler2D atlas; out vec4 color; void main(){color=texture(atlas,uv);}");
    const edge = program(`
      layout(location=0) in vec2 pos; layout(location=1) in vec2 ids; layout(location=2) in float level; out vec4 ink;
      void main(){gl_Position=clip(pos*lens.x+view.zw);
        float a=any(equal(ids,vec2(lens.z)))?min(.8,.1+level*.55):clamp(lens.w*level,0.,.48);
        ink=vec4(lens.y>0.?vec3(.16,.30,.37):vec3(.48,.64,.68),a);}`,
      "in vec4 ink; out vec4 color; void main(){color=ink;}");
    gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, atlas);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    const buffers = [gl.createBuffer(), gl.createBuffer()];
    const vaos = [[4, 1], [2, 2, 1]].map((sizes, i) => {
      const vao = gl.createVertexArray();
      gl.bindVertexArray(vao); gl.bindBuffer(gl.ARRAY_BUFFER, buffers[i]);
      let offset = 0;
      sizes.forEach((size, j) => {
        gl.enableVertexAttribArray(j);
        gl.vertexAttribPointer(j, size, gl.FLOAT, false, 20, offset);
        gl.vertexAttribDivisor(j, i === 0 ? 1 : 0);
        offset += size * 4;
      });
      return vao;
    });
    return {
      name: "WebGL2",
      upload(arrays) {
        arrays.forEach((data, i) => { gl.bindBuffer(gl.ARRAY_BUFFER, buffers[i]); gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW); });
      },
      draw(camera, counts) {
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.clear(gl.COLOR_BUFFER_BIT);
        for (const [p, i] of [[edge, 1], [dot, 0]]) {
          if (!counts[i]) continue;
          gl.useProgram(p.p); gl.bindVertexArray(vaos[i]);
          gl.uniform4fv(p.view, camera, 0, 4); gl.uniform4fv(p.lens, camera, 4, 4);
          if (i === 1) gl.drawArrays(gl.LINES, 0, counts[1]); else gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, counts[0]);
        }
      },
    };
  }

  function create(canvas, palette, paint) {
    const atlas = sprites(palette), camera = new Float32Array(cameraSize);
    const daylight = palette.map(color => "rgb(" + [1, 3, 5].map(i => Math.round(parseInt(color.slice(i, i + 2), 16) * .62)).join(",") + ")");
    let driver, arrays = [new Float32Array(), new Float32Array()], counts = [0, 0];
    function activate(next) {
      driver = next;
      if (driver) driver.upload(arrays);
      if (canvas) canvas.hidden = !driver;
      const badge = document.getElementById("renderer");
      if (badge) badge.textContent = driver?.name || "Canvas 2D";
      paint();
    }
    async function initialize() {
      let next = null;
      if (canvas) {
        try { next = await webgpu(canvas, atlas, () => activate(null)); } catch {}
        if (!next) { try { next = webgl(canvas, atlas, () => activate(null)); } catch {} }
      }
      activate(next);
    }
    activate(null);
    initialize();
    return {
      upload(nodes, lines) {
        const stars = new Float32Array(nodes.length * 5);
        nodes.forEach((n, i) => stars.set([n.x, n.y, n.radius, n.tile, n.index], i * 5));
        arrays = [stars, lines]; counts = arrays.map(b => b.length / 5);
        driver?.upload(arrays);
      },
      draw(ctx, width, height, ox, oy, scale, light, focus, edgeAlpha, visible) {
        camera.set([width, height, ox, oy, scale, light ? palette.length : 0, focus, edgeAlpha]);
        if (driver) {
          try { driver.draw(camera, counts); return; } catch { activate(null); }
        }

        const lines = arrays[1];
        const batches = Array.from({ length: 6 }, () => new Path2D());
        for (let i = 0; i < lines.length; i += 10) {
          const selected = lines[i + 2] === focus || lines[i + 3] === focus;
          if (!selected && lines[i + 4] * edgeAlpha < .008) continue;
          const ax = ox + lines[i] * scale, ay = oy + lines[i + 1] * scale;
          const bx = ox + lines[i + 5] * scale, by = oy + lines[i + 6] * scale;
          if (Math.max(ax, bx) < 0 || Math.min(ax, bx) > width || Math.max(ay, by) < 0 || Math.min(ay, by) > height) continue;
          const batch = selected ? 5 : Math.min(4, Math.round(lines[i + 4] * 2));
          batches[batch].moveTo(ax, ay); batches[batch].lineTo(bx, by);
        }
        ctx.lineWidth = 1; ctx.strokeStyle = light ? "#294c5e" : "#7ba3ad";
        batches.forEach((path, i) => {
          ctx.globalAlpha = i === 5 ? .38 : Math.min(.48, edgeAlpha * Math.max(.12, i / 2));
          ctx.stroke(path);
        });
        ctx.globalAlpha = 1;
        const specks = new Map(), planets = [];
        for (const n of visible) {
          const r = radius(n, scale, focus);
          if (r >= 2.6 || n.landmark || n.index === focus) { planets.push(n); continue; }
          if (!specks.has(n.tint)) specks.set(n.tint, new Path2D());
          specks.get(n.tint).rect(ox + n.x * scale - r * .7, oy + n.y * scale - r * .7, r * 1.4, r * 1.4);
        }
        for (const [tint, dots] of specks) {
          ctx.fillStyle = (light ? daylight : palette)[tint];
          ctx.fill(dots);
        }
        for (const n of planets) {
          const tile = n.tile + camera[5], r = radius(n, scale, focus) * 3;
          ctx.drawImage(atlas, (tile % columns) * tileSize, Math.floor(tile / columns) * tileSize, tileSize, tileSize,
            ox + n.x * scale - r, oy + n.y * scale - r, 2 * r, 2 * r);
        }
      },
      radius,
    };
  }
  return { create };
})();
