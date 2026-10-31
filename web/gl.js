const VERT = "/shaders/ui.vert.glsl";
const FRAG = "/shaders/ui.frag.glsl";

async function loadText(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
  return await r.text();
}

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.gl = canvas.getContext("webgl2", { antialias: false, alpha: false });
    if (!this.gl) throw new Error("WebGL2 is unavailable in this browser");
    this.program = null;
    this.vao = null;
    this.vbo = null;
    this.atlas = null;
    this.atlasSize = 0;
  }

  async init() {
    const gl = this.gl;
    const vs = await loadText(VERT);
    const fs = await loadText(FRAG);
    this.program = this.compile(vs, fs);
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    this.vbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
    const stride = 72;
    const f = gl.FLOAT, u = gl.UNSIGNED_INT;
    this.attr(0, 4, f, stride, 0);
    this.attr(1, 4, f, stride, 16);
    this.attr(2, 4, f, stride, 32);
    this.attrI(3, u, stride, 48);
    this.attrI(4, u, stride, 52);
    this.attr(5, 1, f, stride, 56);
    this.attr(6, 1, f, stride, 60);
    this.attrI(7, u, stride, 64);
    gl.bindVertexArray(null);
    this.uViewport = gl.getUniformLocation(this.program, "u_viewport");
    this.uAtlas = gl.getUniformLocation(this.program, "u_atlas");
    gl.useProgram(this.program);
    gl.uniform1i(this.uAtlas, 0);
    gl.clearColor(0.02, 0.02, 0.02, 1);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    this.atlas = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.atlas);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  }

  attr(loc, size, type, stride, offset) {
    const gl = this.gl;
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, size, type, false, stride, offset);
    gl.vertexAttribDivisor(loc, 1);
  }
  attrI(loc, type, stride, offset) {
    const gl = this.gl;
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribIPointer(loc, 1, type, stride, offset);
    gl.vertexAttribDivisor(loc, 1);
  }

  compile(vsText, fsText) {
    const gl = this.gl;
    const vs = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vs, vsText);
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(vs));
    const fs = gl.createShader(gl.FRAGMENT_SHADER);
    gl.shaderSource(fs, fsText);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(fs));
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, fs);
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }

  uploadAtlas(ptr, size, memory) {
    const gl = this.gl;
    const bytes = new Uint8Array(memory.buffer, ptr, size * size);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.atlas);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, size, size, 0, gl.RED, gl.UNSIGNED_BYTE, bytes);
    this.atlasSize = size;
  }

  draw(ptr, count, strideFloats, memory, width, height, atlasPtr, atlasSize) {
    const gl = this.gl;
    if (count === 0) return;
    if (atlasSize !== this.atlasSize) this.uploadAtlas(atlasPtr, atlasSize, memory);
    gl.viewport(0, 0, width, height);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(this.program);
    gl.uniform2f(this.uViewport, width, height);
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
    const bytes = new Float32Array(memory.buffer, ptr, count * strideFloats);
    gl.bufferData(gl.ARRAY_BUFFER, bytes, gl.DYNAMIC_DRAW);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.atlas);
    gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, count);
    gl.bindVertexArray(null);
  }
}
