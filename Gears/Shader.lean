namespace Gears

/-- Per-draw uniform block; must match `Gears.Runtime.packUniform` (160 bytes). -/
def wgsl : String := "
struct U {
  mvp   : mat4x4f,
  model : mat4x4f,
  color : vec4f,
  light : vec4f,
};
@group(0) @binding(0) var<uniform> u : U;

struct VOut {
  @builtin(position) pos : vec4f,
  @location(0) n : vec3f,
};

@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f) -> VOut {
  var o : VOut;
  o.pos = u.mvp * vec4f(p, 1.0);
  o.n = (u.model * vec4f(n, 0.0)).xyz;
  return o;
}

@fragment fn fs(i : VOut) -> @location(0) vec4f {
  let n = normalize(i.n);
  let l = normalize(u.light.xyz);
  let d = max(dot(n, l), 0.0);
  let h = normalize(l + vec3f(0.0, 0.0, 1.0));
  let s = pow(max(dot(n, h), 0.0), 32.0) * 0.35;
  return vec4f(u.color.rgb * (0.2 + 0.8 * d) + vec3f(s), 1.0);
}
"

end Gears
