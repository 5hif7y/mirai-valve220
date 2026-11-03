package valve220_mapfile

import "core:fmt"
import "core:strings"

// What every converter produces: entities with their keys in order and their
// brushes, written as a Valve 220 .map, the dialect TrenchBroom, J.A.C.K. and
// the Hammer of GoldSrc read and the loader of this plugin imports. A side is a
// plane facing out of the brush, the texture and its two axes: a point p of the
// side has texel coordinates (u·p/scale.x + shift.x, v·p/scale.y + shift.y).

Side :: struct {
    plane:Plane,
    points:[3][3]f64, // three points of the plane, as the source wrote them; zero: made from plane
    has_points:bool,
    texture:string,
    u,v:[3]f64,       // unit axes
    shift,scale:[2]f64,
}

Brush :: struct {
    sides:[dynamic]Side,
}

Entity :: struct {
    keys:[dynamic][2]string,
    brushes:[dynamic]Brush,
}

Map :: struct {
    entities:[dynamic]Entity,
    warnings:[dynamic]string,
}

entity_get :: proc(e:^Entity,key:string) -> (value:string,found:bool) {
    for kv in e.keys {if kv[0]==key {return kv[1],true}}
    return "",false
}

entity_set :: proc(e:^Entity,key,value:string) {
    for &kv in e.keys {if kv[0]==key {kv[1]=value;return}}
    append(&e.keys,[2]string{key,value})
}

map_warn :: proc(m:^Map,format:string,args:..any) {
    append(&m.warnings,fmt.aprintf(format,..args))
}

// The texture axes Quake and TrenchBroom give a face that says none: the two
// axes of the world plane closest to the face.
default_axes :: proc "contextless" (normal:[3]f64) -> (u,v:[3]f64) {
    axis:=largest_axis(normal)
    switch axis {
    case 2:  u,v={1,0,0},{0,-1,0} // floor and ceiling
    case 0:  u,v={0,1,0},{0,0,-1}
    case:    u,v={1,0,0},{0,0,-1}
    }
    return
}

// The axes, shift and scale of the texture vectors of a compiled map: s =
// vecs[0].xyz·p + vecs[0].w, in texels; a longer axis is a smaller scale.
side_texture_from_vecs :: proc(side:^Side,vecs:[2][4]f64) {
    for i in 0..<2 {
        axis,length:=normalize({vecs[i][0],vecs[i][1],vecs[i][2]})
        scale:=1/length if length!=0 else 1
        if i==0 {side.u=axis} else {side.v=axis}
        side.scale[i]=scale
        side.shift[i]=vecs[i][3]
    }
}

// The entity lump of a BSP, or the entities of a .map without brushes:
// { "key" "value" ... } blocks.
entities_parse :: proc(text:string,m:^Map) -> bool {
    at:=0
    skip_space :: proc(text:string,at:^int) {
        for at^<len(text) {
            c:=text[at^]
            if c==' ' || c=='\t' || c=='\r' || c=='\n' || c==0 {at^+=1;continue}
            if c=='/' && at^+1<len(text) && text[at^+1]=='/' {
                for at^<len(text) && text[at^]!='\n' {at^+=1}
                continue
            }
            break
        }
    }
    quoted :: proc(text:string,at:^int) -> (s:string,ok:bool) {
        if at^>=len(text) || text[at^]!='"' {return "",false}
        start:=at^+1
        end:=start
        for end<len(text) && text[end]!='"' {end+=1}
        if end>=len(text) {return "",false}
        at^=end+1
        return text[start:end],true
    }
    for {
        skip_space(text,&at)
        if at>=len(text) {break}
        if text[at]!='{' {return false}
        at+=1
        e:Entity
        for {
            skip_space(text,&at)
            if at>=len(text) {return false}
            if text[at]=='}' {at+=1;break}
            key:=quoted(text,&at) or_return
            skip_space(text,&at)
            value:=quoted(text,&at) or_return
            append(&e.keys,[2]string{key,value})
        }
        append(&m.entities,e)
    }
    return true
}

@(private)
write_number :: proc(b:^strings.Builder,x:f64) {
    // Whole numbers as such, the rest with what a float of the map keeps.
    if x==f64(i64(x)) && abs(x)<1e15 {
        fmt.sbprintf(b,"%d",i64(x))
        return
    }
    text:=fmt.tprintf("%.6f",x)
    text=strings.trim_right(text,"0")
    text=strings.trim_right(text,".")
    if text=="-0" {text="0"}
    strings.write_string(b,text)
}

@(private)
write_point :: proc(b:^strings.Builder,p:[3]f64) {
    strings.write_string(b,"( ")
    for k in 0..<3 {write_number(b,p[k]);strings.write_byte(b,' ')}
    strings.write_string(b,")")
}

// Three points that describe the side's plane facing out: (p1-p0)×(p2-p0)...
// in the order the loaders read, normal = (p0-p1)×(p2-p1).
side_points :: proc(side:Side) -> [3][3]f64 {
    if side.has_points {return side.points}
    tangent,bitangent:=plane_basis(side.plane.normal)
    p0:=side.plane.normal*side.plane.dist
    // Rounded to whole units where the plane allows it, as editors prefer.
    return {p0,p0+bitangent*64,p0+tangent*64}
}

// The map as Valve 220 text. worldspawn says "mapversion" "220", as TrenchBroom expects.
map_write :: proc(m:^Map,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    strings.write_string(&b,"// Converted to Valve 220 by the map plugins of Mirai\n")
    for &e,i in m.entities {
        fmt.sbprintf(&b,"// entity %d\n{{\n",i)
        if i==0 {
            if _,has:=entity_get(&e,"mapversion");!has {append(&e.keys,[2]string{"mapversion","220"})}
        }
        for kv in e.keys {fmt.sbprintf(&b,"\"%s\" \"%s\"\n",kv[0],kv[1])}
        for brush,j in e.brushes {
            fmt.sbprintf(&b,"// brush %d\n{{\n",j)
            for side in brush.sides {
                p:=side_points(side)
                write_point(&b,p[0]);strings.write_byte(&b,' ')
                write_point(&b,p[1]);strings.write_byte(&b,' ')
                write_point(&b,p[2]);strings.write_byte(&b,' ')
                texture:=side.texture if side.texture!="" else "skip"
                strings.write_string(&b,texture)
                strings.write_string(&b," [ ")
                for k in 0..<3 {write_number(&b,side.u[k]);strings.write_byte(&b,' ')}
                write_number(&b,side.shift.x)
                strings.write_string(&b," ] [ ")
                for k in 0..<3 {write_number(&b,side.v[k]);strings.write_byte(&b,' ')}
                write_number(&b,side.shift.y)
                strings.write_string(&b," ] 0 ")
                write_number(&b,side.scale.x if side.scale.x!=0 else 1)
                strings.write_byte(&b,' ')
                write_number(&b,side.scale.y if side.scale.y!=0 else 1)
                strings.write_byte(&b,'\n')
            }
            strings.write_string(&b,"}\n")
        }
        strings.write_string(&b,"}\n")
    }
    return strings.to_string(b)
}
