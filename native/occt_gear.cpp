// OpenCASCADE side: build an involute spur gear as a B-Rep solid, mesh it, and
// hand the triangles back to Lean as two ByteArrays.
//
// The profile is built tooth by tooth in the XY plane:
//   root arc -> radial line (if the base circle is above the root) -> involute
//   flank -> tip arc -> involute flank -> radial line -> next root arc ...
// OCCT has no native involute curve, so each flank is a B-spline interpolated
// exactly through sampled involute points (GeomAPI_Interpolate).
#include <lean/lean.h>

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Tool.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GC_MakeSegment.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <gp_Ax2.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Profile {
  int z;
  double m, alpha;
  double rp, rb, ra, rf, rs;  // pitch, base, tip, root, flank start
};

double inv(double a) { return std::tan(a) - a; }

// Half-angle of the tooth at radius r, measured from the tooth centre line.
double halfAngle(const Profile& p, double r) {
  double ar = std::acos(std::fmin(1.0, p.rb / r));
  return M_PI / (2.0 * p.z) + inv(p.alpha) - inv(ar);
}

gp_Pnt polar(double r, double a) { return gp_Pnt(r * std::cos(a), r * std::sin(a), 0.0); }

TopoDS_Edge involute(const Profile& p, double centre, double side, int samples) {
  // side = -1: flank on the clockwise side (radius rising), +1: ccw side (radius falling)
  Handle(TColgp_HArray1OfPnt) pts = new TColgp_HArray1OfPnt(1, samples);
  for (int i = 0; i < samples; ++i) {
    double t = double(i) / (samples - 1);
    if (side > 0) t = 1.0 - t;
    double r = p.rs + (p.ra - p.rs) * t;
    pts->SetValue(i + 1, polar(r, centre + side * halfAngle(p, r)));
  }
  GeomAPI_Interpolate interp(pts, Standard_False, 1e-9);
  interp.Perform();
  return BRepBuilderAPI_MakeEdge(interp.Curve());
}

TopoDS_Edge arc(double r, double a0, double a1) {
  return BRepBuilderAPI_MakeEdge(GC_MakeArcOfCircle(polar(r, a0), polar(r, 0.5 * (a0 + a1)), polar(r, a1)).Value());
}

TopoDS_Edge segment(const gp_Pnt& a, const gp_Pnt& b) {
  return BRepBuilderAPI_MakeEdge(GC_MakeSegment(a, b).Value());
}

TopoDS_Shape makeGear(int z, double m, double width, double bore, double alphaDeg) {
  Profile p;
  p.z = z; p.m = m; p.alpha = alphaDeg * M_PI / 180.0;
  p.rp = m * z / 2.0;
  p.rb = p.rp * std::cos(p.alpha);
  p.ra = p.rp + m;
  p.rf = p.rp - 1.25 * m;
  p.rs = std::fmax(p.rb, p.rf);

  BRepBuilderAPI_MakeWire wire;
  const double pitch = 2.0 * M_PI / z;
  const double hs = halfAngle(p, p.rs), ha = halfAngle(p, p.ra);
  for (int i = 0; i < z; ++i) {
    double c = i * pitch;
    if (p.rs > p.rf) wire.Add(segment(polar(p.rf, c - hs), polar(p.rs, c - hs)));
    wire.Add(involute(p, c, -1.0, 24));
    wire.Add(arc(p.ra, c - ha, c + ha));
    wire.Add(involute(p, c, +1.0, 24));
    if (p.rs > p.rf) wire.Add(segment(polar(p.rs, c + hs), polar(p.rf, c + hs)));
    wire.Add(arc(p.rf, c + hs, c + pitch - hs));
  }
  if (!wire.IsDone()) throw Standard_Failure("gear profile wire is not closed");

  TopoDS_Face face = BRepBuilderAPI_MakeFace(wire.Wire(), Standard_True);
  // Extrude centred on z = 0.
  gp_Trsf down; down.SetTranslation(gp_Vec(0, 0, -width / 2));
  face = TopoDS::Face(face.Moved(TopLoc_Location(down)));
  TopoDS_Shape body = BRepPrimAPI_MakePrism(face, gp_Vec(0, 0, width));

  // Boolean: cut the bore.
  gp_Ax2 axis(gp_Pnt(0, 0, -width), gp_Dir(0, 0, 1));
  TopoDS_Shape hole = BRepPrimAPI_MakeCylinder(axis, bore, 2 * width);
  BRepAlgoAPI_Cut cut(body, hole);
  if (!cut.IsDone()) throw Standard_Failure("bore boolean failed");
  return cut.Shape();
}

void pushF32(std::vector<uint8_t>& b, float f) {
  uint8_t tmp[4]; std::memcpy(tmp, &f, 4); b.insert(b.end(), tmp, tmp + 4);
}
void pushU32(std::vector<uint8_t>& b, uint32_t u) {
  uint8_t tmp[4]; std::memcpy(tmp, &u, 4); b.insert(b.end(), tmp, tmp + 4);
}

void meshShape(const TopoDS_Shape& shape, double deflection,
               std::vector<uint8_t>& verts, std::vector<uint8_t>& idx) {
  BRepMesh_IncrementalMesh mesher(shape, deflection, Standard_False, 0.25, Standard_False);
  uint32_t base = 0;
  for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
    const TopoDS_Face& face = TopoDS::Face(ex.Current());
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull()) continue;
    BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);
    const gp_Trsf& tr = loc.Transformation();
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    for (int i = 1; i <= tri->NbNodes(); ++i) {
      gp_Pnt pt = tri->Node(i).Transformed(tr);
      gp_Dir n = tri->Normal(i).Transformed(tr);
      if (reversed) n.Reverse();
      pushF32(verts, float(pt.X())); pushF32(verts, float(pt.Y())); pushF32(verts, float(pt.Z()));
      pushF32(verts, float(n.X()));  pushF32(verts, float(n.Y()));  pushF32(verts, float(n.Z()));
    }
    for (int i = 1; i <= tri->NbTriangles(); ++i) {
      int a, b, c;
      tri->Triangle(i).Get(a, b, c);
      if (reversed) std::swap(b, c);
      pushU32(idx, base + a - 1); pushU32(idx, base + b - 1); pushU32(idx, base + c - 1);
    }
    base += tri->NbNodes();
  }
}

lean_obj_res toByteArray(const std::vector<uint8_t>& v) {
  lean_object* arr = lean_alloc_sarray(1, v.size(), v.size());
  std::memcpy(lean_sarray_cptr(arr), v.data(), v.size());
  return arr;
}

}  // namespace

extern "C" LEAN_EXPORT lean_obj_res lean_occt_gear(uint32_t teeth, double module, double width,
                                                   double bore, double alphaDeg, double deflection) {
  try {
    TopoDS_Shape gear = makeGear(int(teeth), module, width, bore, alphaDeg);
    std::vector<uint8_t> verts, idx;
    meshShape(gear, deflection, verts, idx);
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, toByteArray(verts));
    lean_ctor_set(pair, 1, toByteArray(idx));
    return lean_io_result_mk_ok(pair);
  } catch (const Standard_Failure& e) {
    std::string msg = std::string("OCCT: ") + (e.GetMessageString() ? e.GetMessageString() : "failure");
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg.c_str())));
  }
}
