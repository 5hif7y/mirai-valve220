package valve220_mapfile

import "core:math"

// Planes and convex polygons (windings) in map units. A plane is n·p = d; the
// front of a plane is where n·p > d. The planes of a brush face outwards: the
// solid is behind every one of them.

ON_EPSILON :: 0.1      // map units a point may be off a plane and count as on it
WINDING_SIZE :: 1e6    // half the side of the polygon a plane starts as

Plane :: struct {normal:[3]f64,dist:f64}

dot :: proc "contextless" (a,b:[3]f64) -> f64 {return a.x*b.x+a.y*b.y+a.z*b.z}

cross :: proc "contextless" (a,b:[3]f64) -> [3]f64 {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
}

normalize :: proc "contextless" (v:[3]f64) -> (unit:[3]f64,length:f64) {
    length=math.sqrt(dot(v,v))
    if length==0 {return v,0}
    return v/length,length
}

flip :: proc "contextless" (p:Plane) -> Plane {return {-p.normal,-p.dist}}

// The axis along which v is largest.
largest_axis :: proc "contextless" (v:[3]f64) -> int {
    axis:=0
    for k in 1..<3 {if abs(v[k])>abs(v[axis]) {axis=k}}
    return axis
}

// Two vectors along the plane whose cross product, tangent × bitangent, is
// its normal: points p0, p0+bitangent, p0+tangent describe it in a .map.
plane_basis :: proc "contextless" (normal:[3]f64) -> (tangent,bitangent:[3]f64) {
    axis:=largest_axis(normal)
    other:[3]f64
    other[(axis+1)%3]=1
    tangent,_=normalize(cross(normal,other))
    bitangent=cross(normal,tangent)
    return
}

// A polygon on the plane, large enough to cover any map.
winding_from_plane :: proc(p:Plane,out:^[dynamic][3]f64) {
    clear(out)
    tangent,bitangent:=plane_basis(p.normal)
    center:=p.normal*p.dist
    t,b:=tangent*WINDING_SIZE,bitangent*WINDING_SIZE
    // counter-clockwise around the normal, seen from its front
    append(out,center-t-b,center+t-b,center+t+b,center-t+b)
}

// Keeps the part of w behind p (and on it) in out; false when nothing is left.
winding_clip_back :: proc(w:[][3]f64,p:Plane,out:^[dynamic][3]f64,epsilon:=ON_EPSILON) -> bool {
    clear(out)
    if len(w)==0 {return false}
    for i in 0..<len(w) {
        a,b:=w[i],w[(i+1)%len(w)]
        da,db:=dot(p.normal,a)-p.dist,dot(p.normal,b)-p.dist
        if da<=epsilon {append(out,a)}
        if (da>epsilon && db< -epsilon) || (da< -epsilon && db>epsilon) {
            t:=da/(da-db)
            append(out,a+(b-a)*t)
        }
    }
    return len(out)>=3
}

// The area of a planar polygon.
winding_area :: proc(w:[][3]f64) -> f64 {
    total:[3]f64
    for i in 2..<len(w) {total+=cross(w[i-1]-w[0],w[i]-w[0])}
    return math.sqrt(dot(total,total))*0.5
}

// The normal of a polygon from its corners, by the sense they go around.
winding_normal :: proc(w:[][3]f64) -> [3]f64 {
    total:[3]f64
    for i in 2..<len(w) {total+=cross(w[i-1]-w[0],w[i]-w[0])}
    n,_:=normalize(total)
    return n
}

winding_center :: proc(w:[][3]f64) -> [3]f64 {
    c:[3]f64
    for p in w {c+=p}
    return c/f64(max(len(w),1))
}
