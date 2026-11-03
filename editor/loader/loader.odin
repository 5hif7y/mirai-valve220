package valve220_loader

import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import importer "mirai:cook/import"
import "mirai:std/serial"
import mm "mirai:std/math"
import "mirai:cook/textures"

// Valve 220 .map, as TrenchBroom writes it: entities of "key" "value" pairs
// and brushes, whose faces are three points, a texture and its texture axes.
// A brush is the intersection of the half-spaces behind its faces, so its
// mesh is the convex polyhedron those planes bound. The brushes of worldspawn,
// func_group and func_detail become one mesh named after the map; each other
// entity with brushes, a mesh of its own. Entities without brushes are
// ignored here. Faces whose texture is skip, nodraw or caulk are not drawn.
//
// The image of a texture is <folder of the map>/textures/<name>.png, unless
// the one that reads the map gives its texels: a converter whose source keeps
// them (a BSP, a WAD) passes them to read_text, and no file is written.

// The texels of textures by name, as a converter gives them to read_text.
Images :: map[string]textures.Source

MAP_UNITS_PER_METER :: 32
MAP_MAX_BRUSH_PLANES :: 64
MAP_TEXTURE_FALLBACK :: 64.0 // the size, in texels, of a texture whose image is not found

// Textures the tools use to mark the hidden sides of brushes. `sky` no se dibuja: en GoldSrc
// esa cara deja ver el cielo del mapa, y en Mirai el fondo lo pone el Ajuste `Sky`.
@(private="file")
MAP_HIDDEN_TEXTURES :: [?]string{"skip","nodraw","caulk","sky"}

@(private="file")
Map_Face :: struct {
    normal:[3]f64,  // outwards, unit length, in map units
    d:f64,          // dot(normal,p)==d on the plane
    texture:string,
    u,v:[3]f64,     // texture axes, divided by their scale
    offset:[2]f64,
    line:int,
}

@(private="file")
Map_Texture :: struct {
    material:int,
    size:[2]f64,
}

@(private="file")
Map_Lexer :: struct {
    text:string,
    at:int,
    line:int,
}

@(private="file")
Map_Group :: struct {
    builder:importer.Mesh_Builder,
    name:string,
    slot_of:map[string]int,
}

@(private="file")
Map_State :: struct {
    c:^importer.Reader,
    lexer:Map_Lexer,
    textures:map[string]Map_Texture,
    images:Images, // texels given by the one that reads the map, before the files
    faces:[dynamic]Map_Face,
    points:[dynamic][3]f32,
    polygon:[dynamic][3]f32,
    triangles:[dynamic][3]int,
    scratch2:[dynamic][2]f32,
    result:[dynamic]u32,
    degenerate_faces:int,   // caras sin área o cuyo polígono se cierra en menos de 3 esquinas
    empty_brushes:int,      // brushes que no aportaron ningún triángulo
}

FORMAT :: importer.Format{
    name="Valve map",
    extensions={0=".map"},
    version=0,
    space={meters_per_unit=1.0/MAP_UNITS_PER_METER,axes={.X,.Z,.Negative_Y},v_origin=.Top},
    sniff=sniff,
    read=read,
}

// Nothing starts a map: a file named .map is read as one.
sniff :: proc(head:[]u8) -> importer.Sniff {return .Extension}

// A character that ends a bare token.
@(private="file")
map_delimiter :: proc "contextless" (b:u8) -> bool {
    return b==' ' || b=='\t' || b=='\r' || b=='\n' || b=='(' || b==')' ||
        b=='[' || b==']' || b=='{' || b=='}' || b=='"'
}

// The next token: a quoted string without its quotes, one of ( ) [ ] { }, or
// a run of other characters. Comments run from // to the end of the line.
@(private="file")
map_token :: proc(l:^Map_Lexer) -> (token:string,quoted:bool,ok:bool) {
    for l.at<len(l.text) {
        b:=l.text[l.at]
        if b=='\n' {l.line+=1;l.at+=1;continue}
        if b==' ' || b=='\t' || b=='\r' {l.at+=1;continue}
        if b=='/' && l.at+1<len(l.text) && l.text[l.at+1]=='/' {
            for l.at<len(l.text) && l.text[l.at]!='\n' {l.at+=1}
            continue
        }
        break
    }
    if l.at>=len(l.text) {return "",false,false}
    start:=l.at
    c:=l.text[l.at]
    if c=='"' {
        l.at+=1
        for l.at<len(l.text) && l.text[l.at]!='"' && l.text[l.at]!='\n' {l.at+=1}
        if l.at>=len(l.text) || l.text[l.at]!='"' {return "",true,false}
        l.at+=1
        return l.text[start+1:l.at-1],true,true
    }
    // "{" abre una entidad o un brush, salvo cuando empieza el nombre de una
    // textura enmascarada de GoldSrc: `{glass`, `{dust_kasbah`.
    is_name:=(c=='{' && l.at+1<len(l.text) && !map_delimiter(l.text[l.at+1]))
    if !is_name && (c=='(' || c==')' || c=='[' || c==']' || c=='{' || c=='}') {
        l.at+=1
        return l.text[start:l.at],false,true
    }
    if is_name {l.at+=1} // el "{" inicial no es delimitador de este token
    for l.at<len(l.text) && !map_delimiter(l.text[l.at]) {l.at+=1}
    return l.text[start:l.at],false,true
}

@(private="file")
map_expect :: proc(s:^Map_State,wanted:string) -> bool {
    token,quoted,ok:=map_token(&s.lexer)
    if !ok || quoted || token!=wanted {
        return importer.fail(s.c,.Malformed,"map line %d: %s expected",s.lexer.line,wanted)
    }
    return true
}

@(private="file")
map_number :: proc(s:^Map_State) -> (value:f64,ok:bool) {
    token,quoted,read:=map_token(&s.lexer)
    parsed:bool
    if read && !quoted {value,parsed=strconv.parse_f64(token)}
    if !parsed || value-value!=0 {
        return 0,importer.fail(s.c,.Malformed,"map line %d: a number expected",s.lexer.line)
    }
    return value,true
}

@(private="file")
map_point :: proc(s:^Map_State) -> (p:[3]f64,ok:bool) {
    map_expect(s,"(") or_return
    for k in 0..<3 {p[k]=map_number(s) or_return}
    map_expect(s,")") or_return
    return p,true
}

// A face in the Valve 220 form: three points, a texture, then the texture
// axes [ u ] [ v ], rotation, and the scales. The axes carry the rotation, so
// the number after them is read and ignored.
@(private="file")
map_face :: proc(s:^Map_State) -> bool {
    face:=Map_Face{line=s.lexer.line}
    p0:=map_point(s) or_return
    p1:=map_point(s) or_return
    p2:=map_point(s) or_return
    a,b:=p0-p1,p2-p1
    normal:=[3]f64{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
    length:=math.sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
    texture,texture_quoted,read:=map_token(&s.lexer)
    // "{": textura enmascarada de GoldSrc (`{glass`), parte del nombre, no un delimitador.
    if !read || texture=="" || texture_quoted || strings.contains_any(texture,"()[]") {
        return importer.fail(s.c,.Malformed,"map line %d: a face needs a texture",face.line)
    }
    face.texture=texture
    map_expect(s,"[") or_return
    for k in 0..<3 {face.u[k]=map_number(s) or_return}
    face.offset.x=map_number(s) or_return
    map_expect(s,"]") or_return
    map_expect(s,"[") or_return
    for k in 0..<3 {face.v[k]=map_number(s) or_return}
    face.offset.y=map_number(s) or_return
    map_expect(s,"]") or_return
    _=map_number(s) or_return // rotation, already in the axes
    scale_x:=map_number(s) or_return
    scale_y:=map_number(s) or_return
    if scale_x==0 {scale_x=1}
    if scale_y==0 {scale_y=1}
    face.u/=scale_x
    face.v/=scale_y
    if length<1e-9 || length-length!=0 {
        s.degenerate_faces+=1
        return true
    }
    face.normal=normal/length
    face.d=face.normal.x*p0.x+face.normal.y*p0.y+face.normal.z*p0.z
    if len(s.faces)>=MAP_MAX_BRUSH_PLANES {
        return importer.fail(s.c,.Limit,"map line %d: a brush has more than %d faces",
            face.line,MAP_MAX_BRUSH_PLANES)
    }
    append(&s.faces,face)
    return true
}

// The material of a texture name and the size of its image, made the first
// time a face uses it. The image is <folder of the map>/textures/<name>.png.
@(private="file")
map_texture :: proc(s:^Map_State,name:string) -> Map_Texture {
    if known,found:=s.textures[name];found {return known}
    c:=s.c
    images:[asset.Material_Map_Kind]int
    for &image in images {image=-1}
    info:=asset.MATERIAL_DEFAULTS
    // "{glass": textura enmascarada de GoldSrc; su alpha viene del PNG.
    if strings.has_prefix(name,"{") {
        info.alpha_mode=.Mask
        info.alpha_cutoff=0.5
    }
    entry:=Map_Texture{size={MAP_TEXTURE_FALLBACK,MAP_TEXTURE_FALLBACK}}
    path,_:=filepath.join(
        {c.directory,"textures",strings.concatenate({name,".png"},context.temp_allocator)},
        context.temp_allocator,
    )
    if given,has:=s.images[name];has && given.width>0 {
        images[.Base_Color]=importer.image_pixels(c,strings.concatenate({"texels:",name},context.temp_allocator),name,given,true,false)
        entry.size={f64(given.width),f64(given.height)}
    } else if size,found:=png_size(path);found && !importer.unsafe_path(path) {
        images[.Base_Color]=importer.image_file(c,path,true,false)
        entry.size={f64(size.x),f64(size.y)}
    } else {
        importer.warn(c,"texture %s: %s does not exist",name,path)
        info.base_color={0.8,0.8,0.8}
    }
    entry.material=importer.material_add(c,name,len(c.materials),info,images)
    s.textures[strings.clone(name,context.temp_allocator)]=entry
    return entry
}

// Width and height of a PNG file, from its header.
@(private="file")
png_size :: proc(path:string) -> (size:[2]u32,ok:bool) {
    header:[24]u8
    head,_,error:=serial.file_read_head(path,header[:])
    if error!=.None || len(head)<24 {return}
    if string(head[:8])!="\x89PNG\r\n\x1a\n" || string(head[12:16])!="IHDR" {return}
    be :: proc(b:[]u8) -> u32 {return u32(b[0])<<24|u32(b[1])<<16|u32(b[2])<<8|u32(b[3])}
    size={be(head[16:20]),be(head[20:24])}
    return size,size.x>0 && size.y>0
}

@(private="file")
map_hidden :: proc(texture:string) -> bool {
    name:=texture
    if slash:=strings.last_index_byte(name,'/');slash>=0 {name=name[slash+1:]}
    for candidate in MAP_HIDDEN_TEXTURES {
        if strings.equal_fold(name,candidate) {return true}
    }
    return false
}

@(private="file")
dot3 :: proc "contextless" (a,b:[3]f64) -> f64 {return a.x*b.x+a.y*b.y+a.z*b.z}

@(private="file")
cross3 :: proc "contextless" (a,b:[3]f64) -> [3]f64 {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}
}

// The point where three planes meet, when they are not near parallel.
@(private="file")
plane_intersection :: proc(a,b,c:Map_Face) -> (p:[3]f64,ok:bool) {
    bc:=cross3(b.normal,c.normal)
    det:=dot3(a.normal,bc)
    if math.abs(det)<1e-9 {return {},false}
    ca:=cross3(c.normal,a.normal)
    ab:=cross3(a.normal,b.normal)
    p=(bc*a.d+ca*b.d+ab*c.d)/det
    return p,true
}

// A point is in the solid when it is behind (or on) every face plane.
@(private="file")
point_inside :: proc(p:[3]f64,faces:[]Map_Face,tolerance:f64) -> bool {
    for face in faces {
        if dot3(face.normal,p)-face.d>tolerance {return false}
    }
    return true
}

@(private="file")
map_uv :: proc "contextless" (face:Map_Face,p:[3]f32,size:[2]f64) -> [2]f32 {
    q:=[3]f64{f64(p.x),f64(p.y),f64(p.z)}
    return [2]f32{
        f32((dot3(q,face.u)+face.offset.x)/size.x),
        f32((dot3(q,face.v)+face.offset.y)/size.y),
    }
}

// Sorts the corners counter-clockwise around the face normal, seen from it.
@(private="file")
order_face :: proc(points:[][3]f32,normal:[3]f32) {
    if len(points)<3 {return}
    center:[3]f32
    for p in points {center+=p}
    center/=f32(len(points))
    ref:=points[0]-center
    for p in points {
        if r:=p-center;r!={} {ref=r;break}
    }
    u:=ref-normal*linalg.dot(ref,normal)
    if linalg.length(u)<1e-9 {
        u=[3]f32{1,0,0}-normal*linalg.dot([3]f32{1,0,0},normal)
        if linalg.length(u)<1e-9 {u=[3]f32{0,1,0}-normal*linalg.dot([3]f32{0,1,0},normal)}
    }
    u=linalg.normalize(u)
    v:=linalg.cross(normal,u)
    angle := proc(p,center,u,v:[3]f32) -> f32 {
        r:=p-center
        return math.atan2(linalg.dot(r,v),linalg.dot(r,u))
    }
    for i in 1..<len(points) {
        j:=i
        for j>0 && angle(points[j],center,u,v)<angle(points[j-1],center,u,v) {
            points[j],points[j-1]=points[j-1],points[j]
            j-=1
        }
    }
}

// Drops corners that coincide after the intersection rounding.
@(private="file")
dedup_face :: proc(points:^[dynamic][3]f32) {
    out:=0
    for i in 0..<len(points) {
        p:=points[i]
        if out>0 && linalg.length(p-points[out-1])<1e-4 {continue}
        points[out]=p
        out+=1
    }
    if out>1 && linalg.length(points[out-1]-points[0])<1e-4 {out-=1}
    resize(points,out)
}

// The corners of the brush of s.faces, as the points where three of its
// planes meet behind all the others. Each face is the convex polygon of the
// corners that lie on it, triangulated into the group's builder.
@(private="file")
map_brush :: proc(s:^Map_State,group:^Map_Group) -> bool {
    c:=s.c
    faces:=s.faces[:]
    clear(&s.points)
    if len(faces)<4 {
        s.empty_brushes+=1
        return true
    }
    extent:f64=1
    for f in faces {extent=math.max(extent,math.abs(f.d))}
    tolerance:=extent*1e-6
    for i in 0..<len(faces) {
        for j in i+1..<len(faces) {
            for k in j+1..<len(faces) {
                p,ok:=plane_intersection(faces[i],faces[j],faces[k])
                if !ok || !point_inside(p,faces,tolerance) {continue}
                append(&s.points,[3]f32{f32(p.x),f32(p.y),f32(p.z)})
            }
        }
    }
    for face,i in faces {
        clear(&s.polygon)
        for p in s.points {
            q:=[3]f64{f64(p.x),f64(p.y),f64(p.z)}
            if math.abs(dot3(face.normal,q)-face.d)<=tolerance {append(&s.polygon,p)}
        }
        if len(s.polygon)<3 {continue}
        normal:=[3]f32{f32(face.normal.x),f32(face.normal.y),f32(face.normal.z)}
        order_face(s.polygon[:],normal)
        dedup_face(&s.polygon)
        if len(s.polygon)<3 {s.degenerate_faces+=1;continue}
        if map_hidden(face.texture) {continue}
        texture:=map_texture(s,face.texture)
        slot,known:=group.slot_of[face.texture]
        if !known {
            // Un mesh no pasa de MESH_MAX_SLOTS materiales: el grupo sigue en otro mesh.
            if len(group.builder.slots)>=asset.MESH_MAX_SLOTS {map_group_flush(c,group)}
            ok:bool
            slot,ok=importer.builder_slot(
                &group.builder,u32(len(group.builder.slots)+1),face.texture,texture.material,
            )
            if !ok {return false}
            group.slot_of[strings.clone(face.texture,context.temp_allocator)]=slot
        }
        clear(&s.triangles)
        if !importer.polygon_triangulate(c,s.polygon[:],&s.triangles,&s.scratch2,&s.result) {
            s.degenerate_faces+=1
            continue
        }
        for triangle in s.triangles {
            corners:[3]importer.Corner
            for corner,m in triangle {
                p:=s.polygon[corner]
                corners[m]=importer.Corner{
                    position=p,normal=normal,uv=map_uv(face,p,texture.size),
                    has_uv=true,color=importer.WHITE,
                }
            }
            importer.builder_triangle(&group.builder,slot,corners)
        }
    }
    return true
}

@(private="file")
map_group_init :: proc(group:^Map_Group,c:^importer.Reader,name:string) {
    importer.builder_init(&group.builder,c)
    group.name=name
    group.slot_of=make(map[string]int,context.temp_allocator)
}

@(private="file")
map_group_flush :: proc(c:^importer.Reader,group:^Map_Group) {
    if importer.builder_triangles(&group.builder)>0 {
        mesh:=importer.builder_finish(&group.builder,group.name)
        row:=importer.mesh_add(c,mesh)
        append(&c.nodes,importer.Imported_Node{
            name=c.meshes[row].name,parent=-1,transform=mm.TRANSFORM_IDENTITY,mesh=row,visible=true,
        })
    }
    // El builder vuelve a empezar: un mapa grande no entra en un mesh de
    // MESH_MAX_SLOTS materiales ni en los vértices de uno solo.
    importer.builder_init(&group.builder,c)
    clear(&group.slot_of)
}

// Entities whose brushes are the world: one mesh named after the map.
@(private="file")
map_world_class :: proc(classname:string) -> bool {
    return classname=="" || classname=="worldspawn" ||
        classname=="func_group" || classname=="func_detail"
}

read :: proc(c:^importer.Reader,bytes:[]u8) -> bool {
    return read_text(c,string(bytes))
}

// Reads the text of a map into c: what a converter calls with the Valve 220
// it made, and the texels of the textures its source keeps.
read_text :: proc(c:^importer.Reader,text:string,images:Images=nil) -> bool {
    s:Map_State
    s.c=c
    s.images=images
    s.lexer={text=text,line=1}
    s.textures=make(map[string]Map_Texture,context.temp_allocator)
    s.faces.allocator=context.temp_allocator;s.points.allocator=context.temp_allocator
    s.polygon.allocator=context.temp_allocator
    s.triangles.allocator=context.temp_allocator;s.scratch2.allocator=context.temp_allocator
    s.result.allocator=context.temp_allocator
    world:Map_Group
    map_group_init(&world,c,c.stem)
    entities:=0
    for {
        token,quoted,ok:=map_token(&s.lexer)
        if !ok {
            if quoted {
                return importer.fail(c,.Malformed,
                    "map line %d: a quoted string is not closed",s.lexer.line)
            }
            break
        }
        if quoted || token!="{" {
            return importer.fail(c,.Malformed,
                "map line %d: %s expected before an entity",s.lexer.line,"{")
        }
        entities+=1
        classname,name:string
        own_group:Map_Group
        group:^Map_Group
        brushes:=0
        line:=s.lexer.line
        entity: for {
            token,quoted,ok=map_token(&s.lexer)
            if !ok && quoted {
                return importer.fail(c,.Malformed,
                    "map line %d: a quoted string is not closed",s.lexer.line)
            }
            if !ok {
                return importer.fail(c,.Malformed,
                    "map line %d: the entity of line %d is not closed",s.lexer.line,line)
            }
            switch {
            case quoted:
                key:=token
                value,value_quoted,read:=map_token(&s.lexer)
                if !read && value_quoted {
                    return importer.fail(c,.Malformed,
                        "map line %d: a quoted string is not closed",s.lexer.line)
                }
                if !read || !value_quoted {
                    return importer.fail(c,.Malformed,
                        "map line %d: key %s needs a quoted value",s.lexer.line,key)
                }
                switch key {
                case "classname": classname=value
                case "targetname","name": name=value
                }
            case token=="}":
                break entity
            case token=="{":
                if group==nil {
                    if map_world_class(classname) {
                        group=&world
                    } else {
                        map_group_init(&own_group,c,name if name!="" else classname)
                        group=&own_group
                    }
                }
                clear(&s.faces)
                for {
                    save:=s.lexer
                    next,next_quoted,more:=map_token(&s.lexer)
                    if !more {
                        return importer.fail(c,.Malformed,
                            "map line %d: a brush is not closed",s.lexer.line)
                    }
                    if !next_quoted && next=="}" {break}
                    if next_quoted || next!="(" {
                        return importer.fail(c,.Malformed,
                            "map line %d: a face or %s expected in a brush",s.lexer.line,"}")
                    }
                    s.lexer=save
                    map_face(&s) or_return
                }
                map_brush(&s,group) or_return
                brushes+=1
            case:
                return importer.fail(c,.Malformed,"map line %d: %s in an entity",s.lexer.line,token)
            }
        }
        if group==&own_group {map_group_flush(c,&own_group)}
        if brushes>0 || map_world_class(classname) {continue}
        // An entity without brushes has no geometry for this loader.
    }
    if entities==0 {
        return importer.fail(c,.Malformed,"map line %d: the map has no entities",s.lexer.line)
    }
    map_group_flush(c,&world)
    if s.empty_brushes>0 {
        importer.warn(c,"%d brushes without volume were skipped",s.empty_brushes)
    }
    if s.degenerate_faces>0 {
        importer.warn(c,"%d faces without area were skipped",s.degenerate_faces)
    }
    return true
}
