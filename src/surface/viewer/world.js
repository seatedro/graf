"use strict";

const SurveyWorld = (() => {
  const slots = 49, palette = 4, sectorSlot = 24, maxSectors = 24;
  const bodyStride = 12, laneStride = 6, extent = 3.2;
  const corners = "vec2f(-1,-1), vec2f(1,-1), vec2f(-1,1), vec2f(-1,1), vec2f(1,-1), vec2f(1,1)";

  function radius(n, scale, focus) {
    return Math.min(30, Math.max(1.2, n.radius * Math.sqrt(scale))) * (n.index === focus ? 1.5 : 1);
  }

  const glsl = {
    head: "#version 300 es\nprecision highp float;\nuniform vec4 U[49];\n",
    clip: "vec4 clip(vec2 p){return vec4(p/U[0].xy*vec2(2,-2)+vec2(-1,1),0,1);}\n",
    noise: `
      float h21(vec2 q){vec2 p=fract(q*vec2(233.34,851.73));p+=dot(p,p+23.45);return fract(p.x*p.y);}
      vec3 h33(vec2 q){vec3 p=fract(vec3(q.xyx)*vec3(.1031,.103,.0973));p+=dot(p,p.yxz+33.33);return fract((p.xxy+p.yzz)*p.zyx);}
      float vn(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);
        return mix(mix(h21(i),h21(i+vec2(1,0)),f.x),mix(h21(i+vec2(0,1)),h21(i+vec2(1,1)),f.x),f.y);}
      float fbm(vec2 q){vec2 p=q;float v=0.,a=.5;for(int i=0;i<4;i++){v+=a*vn(p);p=p*2.03+vec2(17.1,9.2);a*=.5;}return v*1.07;}
    `,
  };

  const nebulaGlsl = `
    out vec4 color;
    void main(){
      vec2 p=gl_FragCoord.xy/U[48].xy*U[0].xy; p.y=U[0].y-p.y;
      float s=U[1].x, fs=max(U[2].y,1e-4), light=U[1].y;
      vec2 mid=U[0].xy*.5, rel=p-mid, cam=(mid-U[0].zw)/s;
      vec2 w=cam+rel*(1./s+.45/fs);
      vec3 neb=vec3(0); float dens=0.;
      int count=int(U[2].w);
      for(int i=0;i<24;i++){ if(i>=count) break; vec4 sc=U[24+i]; vec2 d=(w-sc.xy)/sc.z; float g=exp(-dot(d,d)*.9); neb+=U[4+int(sc.w)].rgb*g; dens+=g; }
      vec2 q=w*fs/300.;
      float wisp=0., dust=0.;
      if(dens>.015){
        float warp=fbm(q*.8+vec2(3.1,7.7));
        wisp=smoothstep(.28,.92,fbm(q*1.7+warp*1.5));
        dust=smoothstep(.5,.8,vn(q*2.4+11.3+warp)*.66+vn(q*4.9+3.7)*.34);
      }
      vec2 wf=(cam+rel*(1./s+9./fs))*fs/700.;
      float band=exp(-pow(dot(wf,vec2(.35,-.94))+.15,2.)*2.2)*(.35+.65*(vn(wf*3.1+4.)*.6+vn(wf*7.3+1.)*.4));
      vec3 col=mix(vec3(.008,.012,.026),vec3(.022,.018,.046),smoothstep(-.7,.9,rel.y/U[0].y-rel.x/U[0].x*.5));
      col+=vec3(.05,.06,.1)*band+neb*(.07+.4*wisp)*(1.-.7*dust);
      vec3 tn=neb/max(dens,1e-3);
      tn=clamp((tn-min(min(tn.r,tn.g),tn.b))*2.2,0.,1.);
      if(light>.5) col=vec3(.902,.918,.944)*(1.-.2*min(dens,1.)*(.35+.65*wisp)*(vec3(1)-tn*.85))-vec3(.03,.03,.02)*band;
      color=vec4(col,dust);
    }
  `;

  const skyGlsl = `
    uniform sampler2D N;
    out vec4 color;
    void main(){
      vec2 p=vec2(gl_FragCoord.x/U[3].x, U[0].y-gl_FragCoord.y/U[3].x);
      vec4 nb=texture(N,gl_FragCoord.xy/(U[0].xy*U[3].x));
      float s=U[1].x, fs=max(U[2].y,1e-4), t=U[2].x*U[3].z;
      vec2 mid=U[0].xy*.5, rel=p-mid, cam=(mid-U[0].zw)/s;
      vec3 st=vec3(0);
      for(int l=0;l<3;l++){
        float k=l==0?7.:l==1?2.6:.9, cell=l==0?150.:l==1?190.:270., odds=l==0?.6:l==1?.45:.32;
        float sl=1./(1./s+k/fs);
        vec2 g=(cam+rel/sl)*fs/cell, id=floor(g), f=fract(g);
        vec3 h=h33(id+float(l)*31.7);
        if(h.x<odds){
          vec2 at=h.yz*.7+.15;
          vec3 k2=h33(id+vec2(5.1,9.7));
          float dpx=length(f-at)*cell*sl/fs, size=mix(.5,1.15,k2.x)*(l==2?1.45:1.);
          float b=exp(-dpx*dpx/(size*size))*mix(.3,1.,k2.y)*(l==0?.5:l==1?.78:1.);
          b*=1.+.35*sin(t*(1.+h.x*3.)+h.x*50.)*float(l==2);
          st+=mix(vec3(.72,.82,1.),vec3(1.,.86,.72),k2.z)*b;
        }
      }
      float vig=smoothstep(1.15,.3,length(rel/U[0].xy)*1.35);
      vec3 col=U[1].y>.5?(nb.rgb-vec3(.3,.28,.24)*min(length(st),1.)*.45)*mix(.92,1.,vig):(nb.rgb+st*(1.-.6*nb.a))*mix(.45,1.,vig);
      color=vec4(col+(h21(p+fract(t*7.)*13.)-.5)/128.,1);
    }
  `;

  const bodyVertGlsl = `
    layout(location=0) in vec4 a; layout(location=1) in vec4 b; layout(location=2) in vec4 c;
    out vec2 uv; flat out float px; flat out vec3 tc; flat out vec4 info;
    void main(){
      vec2 k=vec2[6](CORNERS)[gl_VertexID];
      float focus=b.x==U[1].z?1.:0., hov=b.x==U[2].z?1.:0.;
      float rv=smoothstep(b.w,b.w+.22,U[3].y);
      float r=clamp(a.z*sqrt(U[1].x),1.2,30.)*(1.+.5*focus+.15*hov)*(.3+.7*rv);
      float dim=1.-.66*U[3].w*(1.-max(c.x,focus));
      uv=k*EXTENT; px=r; tc=U[4+int(a.w)].rgb; info=vec4(b.y,b.z,rv*dim,0);
      gl_Position=clip(a.xy*U[1].x+U[0].zw+k*r*EXTENT);
    }
  `;

  const bodyFragGlsl = `
    in vec2 uv; flat in float px; flat in vec3 tc; flat in vec4 info; out vec4 color;
    void main(){
      float r=length(uv), seed=info.x, kind=info.y, t=U[2].x*U[3].z, aa=1.2/px;
      if(px<1.6){
        float d=r*px, g=exp(-d*d*.3)*1.1+.18*exp(-d*.55);
        vec3 pc=mix(tc,vec3(1),.25);
        color=(U[1].y>.5?vec4(pc*.62*min(g*.7,1.),min(g*.7,1.)):vec4(pc*g,0))*info.z;
        return;
      }
      vec3 L=normalize(vec3(-.58,-.62,.53));
      float disk=1.-smoothstep(1.-aa,1.+aa,r), glow=0.;
      vec3 col=vec3(0), gcol=tc;
      if(kind<.5){
        float z=sqrt(max(0.,1.-r*r));
        float ang=atan(uv.y,uv.x), gran=(fbm(uv*2.6+seed*40.+t*.12)-.5)*smoothstep(6.,16.,px);
        col=mix(tc*1.05,vec3(1,.97,.92),z*z*.7)*(.5+.5*z)*(1.+.55*gran);
        float spike=(exp(-abs(uv.x)*px*.7)+exp(-abs(uv.y)*px*.7))*exp(-r*.9)*smoothstep(2.,7.,px)*(1.-.7*smoothstep(12.,34.,px));
        float corona=exp(-max(r-1.,0.)*3.2)*step(1.,r)*(.55+.6*vn(vec2(ang*5.+seed*20.,r*2.-t*.25)));
        glow=(.5*corona+.16*exp(-r*1.2)+spike*.45)*(.88+.12*sin(t*1.9+seed*40.))*mix(1.,.6,smoothstep(8.,30.,px));
        gcol=mix(tc,vec3(1),.25);
      } else if(kind<2.5&&kind>1.5){
        float ang=atan(uv.y,uv.x), p=fract(t*.32+seed);
        col=mix(tc,vec3(1),.45);
        float dm=abs(uv.x)+abs(uv.y);
        disk=1.-smoothstep(.56-aa*1.4,.56+aa*1.4,dm);
        col*=.75+.35*smoothstep(.56,0.,dm);
        float ring=exp(-pow((r-1.)*px*.85,2.))*step(.32,abs(sin(2.*ang+.785+seed*6.28+t*.25)));
        float pulse=U[3].z*exp(-pow((r-1.-p*1.7)*px*.55,2.))*(1.-p)*.65;
        glow=ring*.85+pulse+.3*exp(-r*1.7);
      } else {
        vec3 n=vec3(uv,sqrt(max(0.,1.-r*r)));
        float lon=atan(n.x,n.z)+t*.035*(.5+seed), lat=n.y;
        vec2 sp=vec2(lon*1.7,lat*2.4)+seed*61.;
        vec3 surf;
        if(fract(seed*7.31)>.45){
          float f=sin(lat*(7.+seed*9.)+fbm(sp*vec2(.6,2.))*3.)*.5+.5;
          surf=mix(tc*.4,tc*1.08+.06,f);
        } else {
          surf=mix(tc*.36,mix(tc,vec3(.92),.22),smoothstep(.36,.68,fbm(sp*1.4)));
          surf=mix(surf,vec3(.9,.93,.97),smoothstep(.78,.9,abs(lat))*.75);
        }
        float day=smoothstep(-.12,.45,dot(n,L));
        col=surf*(.05+day)+mix(tc,vec3(1),.3)*pow(1.-n.z,2.2)*(.12+.75*day);
        glow=exp(-max(r-1.,0.)*6.)*.45*smoothstep(-.6,.6,dot(normalize(uv+1e-4),L.xy))*step(1.,r)+.13*exp(-r*1.4);
        gcol=mix(tc,vec3(.8,.9,1),.4);
        if(kind>2.5){
          float tilt=-.42+(seed-.5)*.5, cs=cos(tilt), sn=sin(tilt);
          vec2 q=vec2(uv.x*cs-uv.y*sn,(uv.x*sn+uv.y*cs)/.3);
          float rr=length(q);
          float ring=smoothstep(1.38,1.46,rr)*(1.-smoothstep(2.15,2.25,rr))*(.55+.45*sin(rr*31.+seed*9.))*(.6+.4*sin(rr*7.))*.85;
          vec3 rc=mix(tc,vec3(.95,.9,.85),.45)*(.35+.65*smoothstep(-2.,2.,-q.x));
          vec3 pc=col*disk;
          if(q.y>0.){ col=rc*ring+pc*(1.-ring); disk=ring+disk*(1.-ring); }
          else { col=pc+rc*ring*(1.-disk); disk=disk+ring*(1.-disk); }
          col/=max(disk,1e-3);
        }
      }
      float near=smoothstep(1.6,3.4,px), d=r*px;
      float pt=exp(-d*d*.3)*1.1+.18*exp(-d*.55);
      float a=disk*near, g=glow*near+pt*(1.-near);
      vec3 rgb=col*a;
      if(U[1].y>.5){ rgb+=gcol*.5*g*.35; a+=g*.35; } else rgb+=gcol*g;
      color=vec4(rgb,min(a,1.))*info.z;
    }
  `;

  const laneGlsl = `
    layout(location=0) in vec2 pos; layout(location=1) in vec2 ids; layout(location=2) in vec2 lv; out vec4 ink;
    void main(){
      gl_Position=clip(pos*U[1].x+U[0].zw);
      float sel=any(equal(ids,vec2(U[1].z)))?1.:0.;
      float a=mix(clamp(U[1].w*lv.x,0.,.42)*(1.-.72*U[3].w),min(.9,.3+lv.x*.55),sel)*smoothstep(.5,1.,U[3].y);
      vec3 c=mix(U[4+int(lv.y)].rgb,U[23].rgb,.5-.3*sel);
      ink=vec4(c*a,a);
    }
  `;

  const wgslNoise = `
    fn h21(q: vec2f) -> f32 { var p = fract(q * vec2f(233.34, 851.73)); p += dot(p, p + 23.45); return fract(p.x * p.y); }
    fn h33(q: vec2f) -> vec3f { var p = fract(vec3f(q.x, q.y, q.x) * vec3f(0.1031, 0.103, 0.0973)); p += dot(p, p.yxz + 33.33); return fract((p.xxy + p.yzz) * p.zyx); }
    fn vn(p: vec2f) -> f32 {
      let i = floor(p); var f = fract(p); f = f * f * (3.0 - 2.0 * f);
      return mix(mix(h21(i), h21(i + vec2f(1, 0)), f.x), mix(h21(i + vec2f(0, 1)), h21(i + vec2f(1, 1)), f.x), f.y);
    }
    fn fbm(q: vec2f) -> f32 {
      var p = q; var v = 0.0; var a = 0.5;
      for (var i = 0; i < 4; i++) { v += a * vn(p); p = p * 2.03 + vec2f(17.1, 9.2); a *= 0.5; }
      return v * 1.07;
    }
  `;

  const wgsl = `
    struct Scene { u: array<vec4f, 49> }
    @group(0) @binding(0) var<uniform> S: Scene;
    @group(0) @binding(1) var nebula: texture_2d<f32>;
    @group(0) @binding(2) var nebulaSampler: sampler;
    fn clip(p: vec2f) -> vec4f { return vec4f(p / S.u[0].xy * vec2f(2, -2) + vec2f(-1, 1), 0, 1); }
    NOISE

    @vertex fn skyVertex(@builtin(vertex_index) v: u32) -> @builtin(position) vec4f {
      let k = array<vec2f, 3>(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3))[v];
      return vec4f(k, 0, 1);
    }
    @fragment fn nebulaFragment(@builtin(position) frag: vec4f) -> @location(0) vec4f {
      let p = frag.xy / S.u[48].xy * S.u[0].xy;
      let s = S.u[1].x; let fs = max(S.u[2].y, 1e-4); let light = S.u[1].y;
      let mid = S.u[0].xy * 0.5; let rel = p - mid; let cam = (mid - S.u[0].zw) / s;
      let w = cam + rel * (1.0 / s + 0.45 / fs);
      var neb = vec3f(0); var dens = 0.0;
      let count = i32(S.u[2].w);
      for (var i = 0; i < 24; i++) {
        if (i >= count) { break; }
        let sc = S.u[24 + i]; let d = (w - sc.xy) / sc.z; let g = exp(-dot(d, d) * 0.9);
        neb += S.u[4 + i32(sc.w)].rgb * g; dens += g;
      }
      let q = w * fs / 300.0;
      var wisp = 0.0; var dust = 0.0;
      if (dens > 0.015) {
        let warp = fbm(q * 0.8 + vec2f(3.1, 7.7));
        wisp = smoothstep(0.28, 0.92, fbm(q * 1.7 + warp * 1.5));
        dust = smoothstep(0.5, 0.8, vn(q * 2.4 + 11.3 + warp) * 0.66 + vn(q * 4.9 + 3.7) * 0.34);
      }
      let wf = (cam + rel * (1.0 / s + 9.0 / fs)) * fs / 700.0;
      let band = exp(-pow(dot(wf, vec2f(0.35, -0.94)) + 0.15, 2.0) * 2.2) * (0.35 + 0.65 * (vn(wf * 3.1 + 4.0) * 0.6 + vn(wf * 7.3 + 1.0) * 0.4));
      var col = mix(vec3f(0.008, 0.012, 0.026), vec3f(0.022, 0.018, 0.046), smoothstep(-0.7, 0.9, rel.y / S.u[0].y - rel.x / S.u[0].x * 0.5));
      col += vec3f(0.05, 0.06, 0.1) * band + neb * (0.07 + 0.4 * wisp) * (1.0 - 0.7 * dust);
      let tn0 = neb / max(dens, 1e-3);
      let tn = clamp((tn0 - vec3f(min(min(tn0.r, tn0.g), tn0.b))) * 2.2, vec3f(0), vec3f(1));
      if (light > 0.5) { col = vec3f(0.902, 0.918, 0.944) * (1.0 - 0.2 * min(dens, 1.0) * (0.35 + 0.65 * wisp) * (vec3f(1) - tn * 0.85)) - vec3f(0.03, 0.03, 0.02) * band; }
      return vec4f(col, dust);
    }
    @fragment fn skyFragment(@builtin(position) frag: vec4f) -> @location(0) vec4f {
      let nb = textureSample(nebula, nebulaSampler, frag.xy / (S.u[0].xy * S.u[3].x));
      let p = frag.xy / S.u[3].x;
      let s = S.u[1].x; let fs = max(S.u[2].y, 1e-4); let t = S.u[2].x * S.u[3].z;
      let mid = S.u[0].xy * 0.5; let rel = p - mid; let cam = (mid - S.u[0].zw) / s;
      var st = vec3f(0);
      for (var l = 0; l < 3; l++) {
        let k = select(select(0.9, 2.6, l == 1), 7.0, l == 0);
        let cell = select(select(270.0, 190.0, l == 1), 150.0, l == 0);
        let odds = select(select(0.32, 0.45, l == 1), 0.6, l == 0);
        let sl = 1.0 / (1.0 / s + k / fs);
        let g = (cam + rel / sl) * fs / cell; let id = floor(g); let f = fract(g);
        let h = h33(id + f32(l) * 31.7);
        if (h.x < odds) {
          let at = h.yz * 0.7 + 0.15;
          let k2 = h33(id + vec2f(5.1, 9.7));
          let dpx = length(f - at) * cell * sl / fs;
          let size = mix(0.5, 1.15, k2.x) * select(1.0, 1.45, l == 2);
          var b = exp(-dpx * dpx / (size * size)) * mix(0.3, 1.0, k2.y) * select(select(1.0, 0.78, l == 1), 0.5, l == 0);
          b *= 1.0 + 0.35 * sin(t * (1.0 + h.x * 3.0) + h.x * 50.0) * select(0.0, 1.0, l == 2);
          st += mix(vec3f(0.72, 0.82, 1.0), vec3f(1.0, 0.86, 0.72), k2.z) * b;
        }
      }
      let vig = smoothstep(1.15, 0.3, length(rel / S.u[0].xy) * 1.35);
      var col = (nb.rgb + st * (1.0 - 0.6 * nb.a)) * mix(0.45, 1.0, vig);
      if (S.u[1].y > 0.5) { col = (nb.rgb - vec3f(0.3, 0.28, 0.24) * min(length(st), 1.0) * 0.45) * mix(0.92, 1.0, vig); }
      return vec4f(col + (h21(p + fract(t * 7.0) * 13.0) - 0.5) / 128.0, 1);
    }

    struct Body { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) @interpolate(flat) px: f32,
      @location(2) @interpolate(flat) tc: vec3f, @location(3) @interpolate(flat) info: vec4f }
    @vertex fn bodyVertex(@builtin(vertex_index) v: u32, @location(0) a: vec4f, @location(1) b: vec4f, @location(2) c: vec4f) -> Body {
      let k = array<vec2f, 6>(CORNERS)[v];
      let focus = select(0.0, 1.0, b.x == S.u[1].z); let hov = select(0.0, 1.0, b.x == S.u[2].z);
      let rv = smoothstep(b.w, b.w + 0.22, S.u[3].y);
      let r = clamp(a.z * sqrt(S.u[1].x), 1.2, 30.0) * (1.0 + 0.5 * focus + 0.15 * hov) * (0.3 + 0.7 * rv);
      let dim = 1.0 - 0.66 * S.u[3].w * (1.0 - max(c.x, focus));
      var out: Body;
      out.pos = clip(a.xy * S.u[1].x + S.u[0].zw + k * r * EXTENT);
      out.uv = k * EXTENT; out.px = r; out.tc = S.u[4 + i32(a.w)].rgb; out.info = vec4f(b.y, b.z, rv * dim, 0);
      return out;
    }
    @fragment fn bodyFragment(v: Body) -> @location(0) vec4f {
      let uv = v.uv; let px = v.px; let tc = v.tc;
      let r = length(uv); let seed = v.info.x; let kind = v.info.y; let t = S.u[2].x * S.u[3].z; let aa = 1.2 / px;
      if (px < 1.6) {
        let d = r * px; let g = exp(-d * d * 0.3) * 1.1 + 0.18 * exp(-d * 0.55);
        let pc = mix(tc, vec3f(1), 0.25);
        if (S.u[1].y > 0.5) { return vec4f(pc * 0.62 * min(g * 0.7, 1.0), min(g * 0.7, 1.0)) * v.info.z; }
        return vec4f(pc * g, 0) * v.info.z;
      }
      let L = normalize(vec3f(-0.58, -0.62, 0.53));
      var disk = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
      var glow = 0.0; var col = vec3f(0); var gcol = tc;
      if (kind < 0.5) {
        let z = sqrt(max(0.0, 1.0 - r * r));
        let ang = atan2(uv.y, uv.x); let gran = (fbm(uv * 2.6 + seed * 40.0 + t * 0.12) - 0.5) * smoothstep(6.0, 16.0, px);
        col = mix(tc * 1.05, vec3f(1, 0.97, 0.92), z * z * 0.7) * (0.5 + 0.5 * z) * (1.0 + 0.55 * gran);
        let spike = (exp(-abs(uv.x) * px * 0.7) + exp(-abs(uv.y) * px * 0.7)) * exp(-r * 0.9) * smoothstep(2.0, 7.0, px) * (1.0 - 0.7 * smoothstep(12.0, 34.0, px));
        let corona = exp(-max(r - 1.0, 0.0) * 3.2) * step(1.0, r) * (0.55 + 0.6 * vn(vec2f(ang * 5.0 + seed * 20.0, r * 2.0 - t * 0.25)));
        glow = (0.5 * corona + 0.16 * exp(-r * 1.2) + spike * 0.45) * (0.88 + 0.12 * sin(t * 1.9 + seed * 40.0)) * mix(1.0, 0.6, smoothstep(8.0, 30.0, px));
        gcol = mix(tc, vec3f(1), 0.25);
      } else if (kind < 2.5 && kind > 1.5) {
        let ang = atan2(uv.y, uv.x); let p = fract(t * 0.32 + seed);
        col = mix(tc, vec3f(1), 0.45);
        let dm = abs(uv.x) + abs(uv.y);
        disk = 1.0 - smoothstep(0.56 - aa * 1.4, 0.56 + aa * 1.4, dm);
        col *= 0.75 + 0.35 * smoothstep(0.56, 0.0, dm);
        let ring = exp(-pow((r - 1.0) * px * 0.85, 2.0)) * step(0.32, abs(sin(2.0 * ang + 0.785 + seed * 6.28 + t * 0.25)));
        let pulse = S.u[3].z * exp(-pow((r - 1.0 - p * 1.7) * px * 0.55, 2.0)) * (1.0 - p) * 0.65;
        glow = ring * 0.85 + pulse + 0.3 * exp(-r * 1.7);
      } else {
        let n = vec3f(uv, sqrt(max(0.0, 1.0 - r * r)));
        let lon = atan2(n.x, n.z) + t * 0.035 * (0.5 + seed); let lat = n.y;
        let sp = vec2f(lon * 1.7, lat * 2.4) + seed * 61.0;
        var surf: vec3f;
        if (fract(seed * 7.31) > 0.45) {
          let f = sin(lat * (7.0 + seed * 9.0) + fbm(sp * vec2f(0.6, 2.0)) * 3.0) * 0.5 + 0.5;
          surf = mix(tc * 0.4, tc * 1.08 + 0.06, f);
        } else {
          surf = mix(tc * 0.36, mix(tc, vec3f(0.92), 0.22), smoothstep(0.36, 0.68, fbm(sp * 1.4)));
          surf = mix(surf, vec3f(0.9, 0.93, 0.97), smoothstep(0.78, 0.9, abs(lat)) * 0.75);
        }
        let day = smoothstep(-0.12, 0.45, dot(n, L));
        col = surf * (0.05 + day) + mix(tc, vec3f(1), 0.3) * pow(1.0 - n.z, 2.2) * (0.12 + 0.75 * day);
        glow = exp(-max(r - 1.0, 0.0) * 6.0) * 0.45 * smoothstep(-0.6, 0.6, dot(normalize(uv + 1e-4), L.xy)) * step(1.0, r) + 0.13 * exp(-r * 1.4);
        gcol = mix(tc, vec3f(0.8, 0.9, 1), 0.4);
        if (kind > 2.5) {
          let tilt = -0.42 + (seed - 0.5) * 0.5; let cs = cos(tilt); let sn = sin(tilt);
          let q = vec2f(uv.x * cs - uv.y * sn, (uv.x * sn + uv.y * cs) / 0.3);
          let rr = length(q);
          let ring = smoothstep(1.38, 1.46, rr) * (1.0 - smoothstep(2.15, 2.25, rr)) * (0.55 + 0.45 * sin(rr * 31.0 + seed * 9.0)) * (0.6 + 0.4 * sin(rr * 7.0)) * 0.85;
          let rc = mix(tc, vec3f(0.95, 0.9, 0.85), 0.45) * (0.35 + 0.65 * smoothstep(-2.0, 2.0, -q.x));
          let pc = col * disk;
          if (q.y > 0.0) { col = rc * ring + pc * (1.0 - ring); disk = ring + disk * (1.0 - ring); }
          else { col = pc + rc * ring * (1.0 - disk); disk = disk + ring * (1.0 - disk); }
          col /= max(disk, 1e-3);
        }
      }
      let near = smoothstep(1.6, 3.4, px); let d = r * px;
      let pt = exp(-d * d * 0.3) * 1.1 + 0.18 * exp(-d * 0.55);
      var a = disk * near; let g = glow * near + pt * (1.0 - near);
      var rgb = col * a;
      if (S.u[1].y > 0.5) { rgb += gcol * 0.5 * g * 0.35; a += g * 0.35; } else { rgb += gcol * g; }
      return vec4f(rgb, min(a, 1.0)) * v.info.z;
    }

    struct Lane { @builtin(position) pos: vec4f, @location(0) ink: vec4f }
    @vertex fn laneVertex(@location(0) pos: vec2f, @location(1) ids: vec2f, @location(2) lv: vec2f) -> Lane {
      let sel = select(0.0, 1.0, any(ids == vec2f(S.u[1].z)));
      let a = mix(clamp(S.u[1].w * lv.x, 0.0, 0.42) * (1.0 - 0.72 * S.u[3].w), min(0.9, 0.3 + lv.x * 0.55), sel) * smoothstep(0.5, 1.0, S.u[3].y);
      let c = mix(S.u[4 + i32(lv.y)].rgb, S.u[23].rgb, 0.5 - 0.3 * sel);
      return Lane(clip(pos * S.u[1].x + S.u[0].zw), vec4f(c * a, a));
    }
    @fragment fn laneFragment(v: Lane) -> @location(0) vec4f { return v.ink; }
  `.replace("NOISE", wgslNoise).replace("CORNERS", corners).replaceAll("EXTENT", extent.toFixed(1));

  async function webgpu(canvas, onLoss) {
    if (!navigator.gpu) return null;
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter || adapter.info?.isFallbackAdapter) return null;
    const device = await adapter.requestDevice();
    const format = navigator.gpu.getPreferredCanvasFormat();
    const blend = { color: { srcFactor: "one", dstFactor: "one-minus-src-alpha" }, alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" } };
    const module = device.createShaderModule({ code: wgsl });
    const stages = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT;
    const plain = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: stages, buffer: {} }] });
    const sampled = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: stages, buffer: {} },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: {} }, { binding: 2, visibility: GPUShaderStage.FRAGMENT, sampler: {} }] });
    const attributes = (count, size) => Array.from({ length: count }, (_, i) => ({ format: "float32x" + size, shaderLocation: i, offset: i * size * 4 }));
    const pipeline = (layout, vertex, fragment, topology, buffers, target, blended) => device.createRenderPipelineAsync({
      layout: device.createPipelineLayout({ bindGroupLayouts: [layout] }), primitive: { topology },
      vertex: { module, entryPoint: vertex, buffers },
      fragment: { module, entryPoint: fragment, targets: [blended ? { format: target, blend } : { format: target }] },
    });
    const [nebula, sky, lanes, bodies] = await Promise.all([
      pipeline(plain, "skyVertex", "nebulaFragment", "triangle-list", [], "rgba8unorm", false),
      pipeline(sampled, "skyVertex", "skyFragment", "triangle-list", [], format, false),
      pipeline(plain, "laneVertex", "laneFragment", "line-list", [{ arrayStride: laneStride * 4, attributes: attributes(3, 2) }], format, true),
      pipeline(plain, "bodyVertex", "bodyFragment", "triangle-list", [{ arrayStride: bodyStride * 4, stepMode: "instance", attributes: attributes(3, 4) }], format, true),
    ]);
    const uniform = device.createBuffer({ size: slots * 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const sampler = device.createSampler({ minFilter: "linear", magFilter: "linear" });
    const group = device.createBindGroup({ layout: plain, entries: [{ binding: 0, resource: { buffer: uniform } }] });
    const context = canvas.getContext("webgpu");
    if (!context) { device.destroy(); return null; }
    context.configure({ device, format, alphaMode: "opaque" });
    device.lost.then(onLoss);

    let buffers = [], target = null, skyGroup = null;
    return {
      name: "WebGPU",
      upload(arrays) {
        for (const b of buffers) b.destroy();
        buffers = arrays.map(data => {
          const buffer = device.createBuffer({ size: Math.max(64, data.byteLength), usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
          if (data.length) device.queue.writeBuffer(buffer, 0, data);
          return buffer;
        });
      },
      draw(scene, counts, stale) {
        const w = Math.max(1, Math.ceil(canvas.width / 3)), h = Math.max(1, Math.ceil(canvas.height / 3));
        if (target?.width !== w || target?.height !== h) {
          target?.destroy();
          target = device.createTexture({ size: [w, h], format: "rgba8unorm", usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING });
          skyGroup = device.createBindGroup({ layout: sampled, entries: [{ binding: 0, resource: { buffer: uniform } },
            { binding: 1, resource: target.createView() }, { binding: 2, resource: sampler }] });
          stale = true;
        }
        scene.set([w, h], 48 * 4);
        device.queue.writeBuffer(uniform, 0, scene);
        const encoder = device.createCommandEncoder();
        if (stale) {
          const pass = encoder.beginRenderPass({ colorAttachments: [{ view: target.createView(), loadOp: "clear", clearValue: { r: 0, g: 0, b: 0, a: 1 }, storeOp: "store" }] });
          pass.setBindGroup(0, group); pass.setPipeline(nebula); pass.draw(3); pass.end();
        }
        const pass = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(),
          loadOp: "clear", clearValue: { r: 0, g: 0, b: 0, a: 1 }, storeOp: "store" }] });
        pass.setBindGroup(0, skyGroup); pass.setPipeline(sky); pass.draw(3);
        pass.setBindGroup(0, group);
        if (counts[1]) { pass.setPipeline(lanes); pass.setVertexBuffer(0, buffers[1]); pass.draw(counts[1]); }
        if (counts[0]) { pass.setPipeline(bodies); pass.setVertexBuffer(0, buffers[0]); pass.draw(6, counts[0]); }
        pass.end();
        device.queue.submit([encoder.finish()]);
      },
    };
  }

  function webgl(canvas, onLoss) {
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: true, depth: false, stencil: false, premultipliedAlpha: true });
    if (!gl) return null;
    canvas.addEventListener("webglcontextlost", onLoss, { once: true });
    const shader = (type, source) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, glsl.head + glsl.clip + glsl.noise + source.replace("CORNERS", corners.replaceAll("vec2f", "vec2")).replaceAll("EXTENT", extent.toFixed(1)));
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    const program = (vertex, fragment) => {
      const p = gl.createProgram();
      for (const s of [shader(gl.VERTEX_SHADER, vertex), shader(gl.FRAGMENT_SHADER, fragment)]) { gl.attachShader(p, s); gl.deleteShader(s); }
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
      return { p, u: gl.getUniformLocation(p, "U") };
    };
    const screen = "void main(){gl_Position=vec4(vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3))[gl_VertexID],0,1);}";
    const nebula = program(screen, nebulaGlsl), sky = program(screen, skyGlsl);
    const lanes = program(laneGlsl, "in vec4 ink; out vec4 color; void main(){color=ink;}");
    const bodies = program(bodyVertGlsl, bodyFragGlsl);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    const buffers = [gl.createBuffer(), gl.createBuffer()];
    const vaos = [[[4, 4, 4], bodyStride], [[2, 2, 2], laneStride]].map(([sizes, stride], i) => {
      const vao = gl.createVertexArray();
      gl.bindVertexArray(vao); gl.bindBuffer(gl.ARRAY_BUFFER, buffers[i]);
      let offset = 0;
      sizes.forEach((size, j) => {
        gl.enableVertexAttribArray(j);
        gl.vertexAttribPointer(j, size, gl.FLOAT, false, stride * 4, offset);
        gl.vertexAttribDivisor(j, i === 0 ? 1 : 0);
        offset += size * 4;
      });
      return vao;
    });
    const empty = gl.createVertexArray(), texture = gl.createTexture(), framebuffer = gl.createFramebuffer();
    let size = [0, 0];
    return {
      name: "WebGL2",
      upload(arrays) {
        arrays.forEach((data, i) => { gl.bindBuffer(gl.ARRAY_BUFFER, buffers[i]); gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW); });
      },
      draw(scene, counts, stale) {
        const w = Math.max(1, Math.ceil(canvas.width / 3)), h = Math.max(1, Math.ceil(canvas.height / 3));
        gl.disable(gl.BLEND);
        gl.bindVertexArray(empty);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        if (size[0] !== w || size[1] !== h) {
          size = [w, h];
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
          for (const [key, value] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, key, value);
          gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
          gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
          stale = true;
        }
        scene.set([w, h], 48 * 4);
        if (stale) {
          gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
          gl.viewport(0, 0, w, h);
          gl.useProgram(nebula.p); gl.uniform4fv(nebula.u, scene); gl.drawArrays(gl.TRIANGLES, 0, 3);
        }
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(sky.p); gl.uniform4fv(sky.u, scene); gl.drawArrays(gl.TRIANGLES, 0, 3);
        gl.enable(gl.BLEND);
        if (counts[1]) { gl.useProgram(lanes.p); gl.uniform4fv(lanes.u, scene); gl.bindVertexArray(vaos[1]); gl.drawArrays(gl.LINES, 0, counts[1]); }
        if (counts[0]) { gl.useProgram(bodies.p); gl.uniform4fv(bodies.u, scene); gl.bindVertexArray(vaos[0]); gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, counts[0]); }
      },
    };
  }

  function rgb(hex, k = 1) {
    return [1, 3, 5].map(i => Math.min(255, Math.round(parseInt(hex.slice(i, i + 2), 16) * k)));
  }

  function sprites(colors, light) {
    const tile = 64, columns = 8, image = document.createElement("canvas");
    image.width = tile * columns;
    image.height = tile * Math.ceil(colors.length * 4 / columns);
    const c = image.getContext("2d");
    for (let kind = 0; kind < 4; kind++) {
      for (const [index, hex] of colors.entries()) {
        const at = kind * colors.length + index, base = rgb(hex, light ? .62 : 1);
        const tone = (k, add = 0, a = 1) => "rgba(" + base.map(v => Math.min(255, Math.round(v * k + add))).join(",") + "," + a + ")";
        c.save();
        c.translate((at % columns + .5) * tile, (Math.floor(at / columns) + .5) * tile);
        const glow = c.createRadialGradient(0, 0, 2, 0, 0, 31);
        glow.addColorStop(0, tone(1, 30, light ? .3 : .55));
        glow.addColorStop(.35, tone(1, 0, light ? .1 : .18));
        glow.addColorStop(1, tone(1, 0, 0));
        c.fillStyle = glow;
        c.fillRect(-32, -32, 64, 64);
        if (kind === 2) {
          c.strokeStyle = tone(1, 60, .9); c.lineWidth = 1.4;
          for (let q = 0; q < 4; q++) { c.beginPath(); c.arc(0, 0, 10, q * Math.PI / 2 + .25, q * Math.PI / 2 + 1.32); c.stroke(); }
          c.fillStyle = tone(.6, 110); c.beginPath(); c.arc(0, 0, 4.2, 0, 2 * Math.PI); c.fill();
        } else if (kind === 0) {
          c.fillStyle = tone(1, 40, .5);
          c.fillRect(-24, -.6, 48, 1.2); c.fillRect(-.6, -24, 1.2, 48);
          const core = c.createRadialGradient(-1, -1, 0, 0, 0, 10);
          core.addColorStop(0, "#fffdf4"); core.addColorStop(.55, tone(1, 50)); core.addColorStop(1, tone(1, 0, 0));
          c.fillStyle = core; c.beginPath(); c.arc(0, 0, 10, 0, 2 * Math.PI); c.fill();
        } else {
          if (kind === 3) { c.strokeStyle = tone(.8, 50, .55); c.lineWidth = 2.5; c.beginPath(); c.ellipse(0, 0, 19, 5.6, -.42, Math.PI, 2 * Math.PI); c.stroke(); }
          const surface = c.createRadialGradient(-4, -5, 0, 0, 0, 10);
          surface.addColorStop(0, tone(.9, 70)); surface.addColorStop(.5, tone(.95)); surface.addColorStop(.85, tone(.35)); surface.addColorStop(1, tone(.2, 6));
          c.fillStyle = surface; c.beginPath(); c.arc(0, 0, 10, 0, 2 * Math.PI); c.fill();
          c.strokeStyle = tone(1, 60, .5); c.lineWidth = 1; c.beginPath(); c.arc(0, 0, 10, Math.PI * .9, Math.PI * 1.6); c.stroke();
          if (kind === 3) { c.strokeStyle = tone(.8, 50, .7); c.lineWidth = 2.5; c.beginPath(); c.ellipse(0, 0, 19, 5.6, -.42, 0, Math.PI); c.stroke(); }
        }
        c.restore();
      }
    }
    return { image, tile, columns };
  }

  function starfield(size, count, seed, light) {
    const tile = document.createElement("canvas");
    tile.width = tile.height = size;
    const c = tile.getContext("2d");
    let s = seed;
    const rand = () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296;
    for (let i = 0; i < count; i++) {
      const warm = rand(), b = .25 + rand() * .75;
      c.fillStyle = light ? "rgba(60,64,80," + b * .4 + ")" : "rgba(" + Math.round(190 + warm * 65) + "," + Math.round(205 + warm * 15) + "," + Math.round(255 - warm * 70) + "," + b + ")";
      const r = .4 + rand() * .7;
      c.fillRect(rand() * size, rand() * size, r * 1.6, r * 1.6);
    }
    return tile;
  }

  function create(canvas, colors, paint) {
    const scene = new Float32Array(slots * 4);
    let driver, arrays = [new Float32Array(), new Float32Array()], counts = [0, 0], sectors = [], fallback = null, charted = 0, skyKey = "";
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
        try { next = await webgpu(canvas, () => activate(null)); } catch {}
        if (!next) { try { next = webgl(canvas, () => activate(null)); } catch {} }
      }
      activate(next);
    }
    activate(null);
    initialize();

    function tones(light) {
      for (const [i, hex] of colors.entries()) scene.set(rgb(hex, light ? .66 : 1).map(v => v / 255), (palette + i) * 4);
      scene.set(light ? [.2, .3, .38] : [.62, .76, .86], (palette + 19) * 4);
    }

    function paintSky(ctx, v) {
      const { width, height, ox, oy, scale, fitScale, light, time } = v;
      const cx = (width / 2 - ox) / scale, cy = (height / 2 - oy) / scale;
      ctx.fillStyle = light ? "#e6eaf0" : "#04060d";
      ctx.fillRect(0, 0, width, height);
      const sn = 1 / (1 / scale + .45 / fitScale);
      ctx.globalCompositeOperation = light ? "multiply" : "lighter";
      for (const s of sectors) {
        const x = width / 2 + (s.x - cx) * sn, y = height / 2 + (s.y - cy) * sn, r = s.r * sn * 1.5;
        if (x + r < 0 || x - r > width || y + r < 0 || y - r > height) continue;
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        const [cr, cg, cb] = rgb(colors[s.tint], light ? .9 : .55);
        g.addColorStop(0, "rgba(" + cr + "," + cg + "," + cb + "," + (light ? .16 : .2) + ")");
        g.addColorStop(1, "rgba(" + cr + "," + cg + "," + cb + ",0)");
        ctx.fillStyle = g; ctx.fillRect(x - r, y - r, 2 * r, 2 * r);
      }
      ctx.globalCompositeOperation = "source-over";
      fallback.stars ??= [starfield(256, 70, 7, light), starfield(320, 26, 11, light)];
      for (const [i, k] of [6, 1.4].entries()) {
        const tile = fallback.stars[i], size = tile.width, sl = 1 / (1 / scale + k / fitScale);
        const dx = ((-cx * sl) % size + size) % size, dy = ((-cy * sl) % size + size) % size;
        for (let x = dx - size; x < width; x += size) for (let y = dy - size; y < height; y += size) ctx.drawImage(tile, x, y);
      }
    }

    return {
      upload(bodies, lanes, nextSectors) {
        const data = new Float32Array(bodies.length * bodyStride);
        bodies.forEach((n, i) => data.set([n.x, n.y, n.radius, n.tint, n.index, n.seed, n.kind, n.delay, n.related ? 1 : 0], i * bodyStride));
        sectors = nextSectors.slice(0, maxSectors);
        charted++;
        arrays = [data, lanes]; counts = [bodies.length, lanes.length / laneStride];
        driver?.upload(arrays);
      },
      relate(bodies) {
        const data = arrays[0];
        bodies.forEach((n, i) => { data[i * bodyStride + 8] = n.related ? 1 : 0; });
        driver?.upload(arrays);
      },
      draw(ctx, v, visible) {
        const { width, height, ox, oy, scale, light, focus, hover, edgeAlpha, time, fitScale, ratio, reveal, motion, dim } = v;
        scene.set([width, height, ox, oy, scale, light ? 1 : 0, focus, edgeAlpha, time, fitScale, hover, sectors.length, ratio, reveal, motion ? 1 : 0, dim ? 1 : 0]);
        tones(light);
        sectors.forEach((s, i) => scene.set([s.x, s.y, s.r, s.tint], (sectorSlot + i) * 4));
        if (driver) {
          const key = [width, height, ox, oy, scale, light, fitScale, charted].join();
          try { driver.draw(scene, counts, key !== skyKey); skyKey = key; return; } catch { skyKey = ""; activate(null); }
        }

        if (!fallback || fallback.light !== light) fallback = { light, atlas: sprites(colors, light) };
        paintSky(ctx, v);
        const lanes = arrays[1];
        const batches = Array.from({ length: 6 }, () => new Path2D());
        const alive = reveal > .6;
        for (let i = 0; alive && i < lanes.length; i += laneStride * 2) {
          const selected = lanes[i + 2] === focus || lanes[i + 3] === focus;
          if (!selected && lanes[i + 4] * edgeAlpha < .008) continue;
          const ax = ox + lanes[i] * scale, ay = oy + lanes[i + 1] * scale;
          const bx = ox + lanes[i + 6] * scale, by = oy + lanes[i + 7] * scale;
          if (Math.max(ax, bx) < 0 || Math.min(ax, bx) > width || Math.max(ay, by) < 0 || Math.min(ay, by) > height) continue;
          const batch = selected ? 5 : Math.min(4, Math.round(lanes[i + 4] * 2));
          batches[batch].moveTo(ax, ay); batches[batch].lineTo(bx, by);
        }
        ctx.lineWidth = 1; ctx.strokeStyle = light ? "#33505e" : "#8fb4c4";
        batches.forEach((path, i) => {
          ctx.globalAlpha = i === 5 ? .6 : Math.min(.42, edgeAlpha * Math.max(.12, i / 2)) * (dim ? .3 : 1);
          ctx.stroke(path);
        });
        ctx.globalAlpha = 1;
        const { image, tile, columns } = fallback.atlas, specks = new Map(), large = [];
        for (const n of visible) {
          const r = radius(n, scale, focus);
          if (r >= 2.6 || n.index === focus) { large.push(n); continue; }
          if (!specks.has(n.tint)) specks.set(n.tint, new Path2D());
          specks.get(n.tint).rect(ox + n.x * scale - r * .7, oy + n.y * scale - r * .7, r * 1.4, r * 1.4);
        }
        ctx.globalAlpha = dim ? .4 : 1;
        for (const [tint, dots] of specks) {
          ctx.fillStyle = "rgb(" + rgb(colors[tint], light ? .55 : 1).join(",") + ")";
          ctx.fill(dots);
        }
        for (const n of large) {
          const at = n.kind * colors.length + n.tint, r = radius(n, scale, focus) * extent;
          ctx.globalAlpha = dim && !n.related && n.index !== focus ? .4 : 1;
          ctx.drawImage(image, (at % columns) * tile, Math.floor(at / columns) * tile, tile, tile, ox + n.x * scale - r, oy + n.y * scale - r, 2 * r, 2 * r);
        }
        ctx.globalAlpha = 1;
      },
      radius,
    };
  }
  return { create };
})();
