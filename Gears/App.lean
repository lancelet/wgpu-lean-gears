import Gears.Math

/-!
The application, Elm-style: `Model`, `Msg`, a pure `update` that also returns
`Cmd`s for the runtime to perform, and a pure `view` producing a `Scene`.
Nothing here touches IO.
-/
namespace Gears

/-- A gear as requested from OpenCASCADE plus where it sits in the train. -/
structure GearSpec where
  teeth  : Nat
  width  : Float
  bore   : Float
  color  : Vec3
  /-- Direction from the driver gear's centre to this gear's centre (radians). -/
  dir    : Float

/-- Metric module (pitch diameter / teeth) shared by the train so the gears mesh. -/
def gearModule : Float := 0.3
def pressureAngle : Float := 20.0

/-- glxgears' three gears: a 20-tooth driver and two 10-tooth followers. -/
def driver : GearSpec := { teeth := 20, width := 1.0, bore := 1.0, color := ⟨0.8, 0.1, 0.0⟩, dir := 0 }
def followers : List GearSpec :=
  [ { teeth := 10, width := 2.0, bore := 0.5, color := ⟨0.0, 0.8, 0.2⟩, dir := 0 },
    { teeth := 10, width := 0.5, bore := 0.6, color := ⟨0.2, 0.2, 1.0⟩, dir := pi / 2 } ]
def gearSpecs : List GearSpec := driver :: followers

def pitchRadius (g : GearSpec) : Float := gearModule * g.teeth.toFloat / 2

/-- Centre of each gear, driver first; the train is shifted to sit around the origin. -/
def gearCentres : List Vec3 :=
  let cs : List Vec3 := ⟨0, 0, 0⟩ :: followers.map fun g =>
    let d := pitchRadius driver + pitchRadius g
    ⟨d * g.dir.cos, d * g.dir.sin, 0⟩
  cs.map fun c => ⟨c.x - 1.5, c.y - 1.5, c.z⟩

/--
Rotation of each gear for driver angle `a`. A follower turns the other way at
the tooth ratio, phased so one of its gaps faces the driver's tooth along the
line of centres.
-/
def gearAngles (a : Float) : List Float :=
  a :: followers.map fun g =>
    let ratio := driver.teeth.toFloat / g.teeth.toFloat
    g.dir * (1 + ratio) + pi - pi / g.teeth.toFloat - ratio * a

structure Model where
  width   : Float := 1
  height  : Float := 1
  angle   : Float := 0
  running : Bool := true
  viewX   : Float := 20 * pi / 180
  viewY   : Float := 30 * pi / 180
  dist    : Float := 22
  lastT   : Option Float := none
  dragging : Bool := false

inductive Msg where
  | frame  (tMs : Float)
  | resize (w h : Float)
  | drag   (dx dy : Float)
  | orbit  (dx dy : Float)
  | zoom   (factor : Float)
  | key    (code : Nat)
  | quit

inductive Cmd where
  | configureSurface (w h : UInt32)
  | quit

def init : Model := {}

def clamp (lo hi x : Float) : Float := if x < lo then lo else if x > hi then hi else x

def update : Msg → Model → Model × List Cmd
  | .frame t, m =>
    let dt := match m.lastT with
      | some t0 => clamp 0 0.1 ((t - t0) / 1000)
      | none => 0
    ({ m with lastT := some t, angle := if m.running then m.angle + 1.2 * dt else m.angle }, [])
  | .resize w h, m =>
    ({ m with width := w, height := h }, [.configureSurface w.toUInt32 h.toUInt32])
  | .drag dx dy, m | .orbit dx dy, m =>
    ({ m with viewY := m.viewY + dx * 0.008,
              viewX := clamp (-pi / 2) (pi / 2) (m.viewX + dy * 0.008) }, [])
  | .zoom f, m => ({ m with dist := clamp 6 80 (m.dist * f) }, [])
  | .key 32, m => ({ m with running := !m.running }, [])            -- space
  | .key 114, m =>  -- 'r': reset the camera
    ({ m with viewX := init.viewX, viewY := init.viewY, dist := init.dist }, [])
  | .key _, m => (m, [])
  | .quit, m => (m, [.quit])

/-- One draw: which gear mesh, its matrices, its colour. -/
structure Draw where
  mesh  : Nat
  mvp   : Mat4
  model : Mat4
  color : Vec3

structure Scene where
  clear : Vec3
  draws : List Draw

def view (m : Model) : Scene :=
  let proj := Mat4.perspective (35 * pi / 180) (m.width / m.height) 1 200
  let cam := Mat4.translate ⟨0, 0, -m.dist⟩ * Mat4.rotX m.viewX * Mat4.rotY m.viewY
  let draws := (gearSpecs.zip (gearCentres.zip (gearAngles m.angle))).zipIdx.map
    fun ((g, c, a), i) =>
      let mv := cam * Mat4.translate c * Mat4.rotZ a
      { mesh := i, mvp := proj * mv, model := mv, color := g.color }
  { clear := ⟨0.05, 0.05, 0.08⟩, draws }

end Gears
