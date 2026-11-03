package valve220_loader

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"

@(rodata)
FORMATS:=[?]importer.Format{FORMAT}

temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path:=fmt.tprintf("%s/mirai-map-%d-%s",directory,os.get_pid(),name)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

write_text :: proc(folder,name,text:string) -> string {
    path:=fmt.tprintf("%s/%s",folder,name)
    _=os.write_entire_file(path,text)
    return path
}

import_ok :: proc(
    t:^testing.T,path:string,options:importer.Import_Options={},
) -> (model:importer.Imported_Model,ok:bool) {
    error:importer.Error
    model,error=importer.import_model(path,FORMATS[:],options)
    ok=testing.expectf(t,error.code==.None,"%s: %v %s",path,error.code,error.message)
    return
}

triangle_count :: proc(mesh:^importer.Imported_Mesh) -> int {return len(mesh.indices)/3}

close_to :: proc(a,b:[3]f32,tolerance:f32=1e-5) -> bool {return linalg.length(a-b)<tolerance}

FACE_X :: "( %d %d %d ) ( %d %d %d ) ( %d %d %d ) %s [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1\n"
FACE_Y :: "( %d %d %d ) ( %d %d %d ) ( %d %d %d ) %s [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 1 1\n"
FACE_Z :: "( %d %d %d ) ( %d %d %d ) ( %d %d %d ) %s [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1\n"

// One brush: the cube [origin, origin+32] in map units, with Valve 220 faces.
cube_brush :: proc(b:^strings.Builder,origin:[3]int,texture:="dev") {
    x0,y0,z0:=origin.x,origin.y,origin.z
    x1,y1,z1:=x0+32,y0+32,z0+32
    strings.write_string(b,"{\n")
    fmt.sbprintf(b,FACE_X,x0,y0,z0,x0,y1,z0,x0,y0,z1,texture)
    fmt.sbprintf(b,FACE_X,x1,y0,z0,x1,y0,z1,x1,y1,z0,texture)
    fmt.sbprintf(b,FACE_Y,x0,y0,z0,x0,y0,z1,x1,y0,z0,texture)
    fmt.sbprintf(b,FACE_Y,x0,y1,z0,x1,y1,z0,x0,y1,z1,texture)
    fmt.sbprintf(b,FACE_Z,x0,y0,z0,x1,y0,z0,x0,y1,z0,texture)
    fmt.sbprintf(b,FACE_Z,x0,y0,z1,x0,y1,z1,x1,y0,z1,texture)
    strings.write_string(b,"}\n")
}

cube_map :: proc(origins:..[3]int) -> string {
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"{\n\"classname\" \"worldspawn\"\n")
    for origin in origins {cube_brush(&b,origin)}
    strings.write_string(&b,"}\n")
    return strings.to_string(b)
}

@(test)
a_cube_brush_imports_to_a_closed_mesh :: proc(t:^testing.T) {
    folder:=temp_folder("cube")
    defer os.remove_all(folder)
    path:=write_text(folder,"box.map",cube_map({0,0,0}))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,len(model.nodes),1)
    mesh:=&model.meshes[0]
    testing.expect_value(t,triangle_count(mesh),12)
    // 32 map units to the meter, Z up turned to Y up, -Y ahead.
    testing.expect(t,close_to(mesh.bounds_min,{0,0,-1}) && close_to(mesh.bounds_max,{1,1,0}))
    testing.expect_value(t,len(mesh.slots),1)
    testing.expect_value(t,mesh.slots[0].label,"dev")
    testing.expect_value(t,len(model.materials),1)
    testing.expect_value(t,model.materials[0].name,"dev")
    testing.expect_value(t,len(model.warnings),1)
    testing.expect(t,strings.contains(model.warnings[0],"dev"),model.warnings[0])
}

@(test)
brushes_of_the_world_become_one_mesh :: proc(t:^testing.T) {
    folder:=temp_folder("world")
    defer os.remove_all(folder)
    path:=write_text(folder,"two.map",cube_map({0,0,0},{64,0,0}))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,triangle_count(&model.meshes[0]),24)
    testing.expect(t,close_to(model.meshes[0].bounds_min,{0,0,-1}) &&
        close_to(model.meshes[0].bounds_max,{3,1,0}))
}

@(test)
a_flat_brush_is_skipped_with_a_warning :: proc(t:^testing.T) {
    folder:=temp_folder("flat")
    defer os.remove_all(folder)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"{\n\"classname\" \"worldspawn\"\n")
    strings.write_string(&b,"{\n")
    fmt.sbprintf(&b,FACE_X,0,0,0,0,32,0,0,0,32,"dev")
    fmt.sbprintf(&b,FACE_X,32,0,0,32,0,32,32,32,0,"dev")
    fmt.sbprintf(&b,FACE_Y,0,0,0,0,0,32,32,0,0,"dev")
    strings.write_string(&b,"}\n")
    cube_brush(&b,{64,0,0})
    strings.write_string(&b,"}\n")
    path:=write_text(folder,"flat.map",strings.to_string(b))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.meshes),1)
    testing.expect_value(t,triangle_count(&model.meshes[0]),12)
    testing.expect(t,len(model.warnings)>=2,
        "the flat brush and the missing texture are both reported")
    reported:=false
    for warning in model.warnings {
        if strings.contains(warning,"without volume") {reported=true}
    }
    testing.expect(t,reported,"the flat brush is not reported")
}

@(test)
a_broken_map_fails_cleanly :: proc(t:^testing.T) {
    folder:=temp_folder("broken")
    defer os.remove_all(folder)

    path:=write_text(folder,"unclosed.map",`{
"classname" "worldspawn"
{
( 0 0 0 ) ( 0 32 0 ) ( 0 0 32 ) dev [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1
`)
    _,error:=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)

    path=write_text(folder,"empty.map","// nothing\n")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Malformed)
    testing.expect(t,strings.contains(error.message,"no entities"),error.message)

    path=write_text(folder,"model.obj","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
    _,error=importer.import_model(path,FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Unsupported)

    _,error=importer.import_model(fmt.tprintf("%s/missing.map",folder),FORMATS[:])
    testing.expect_value(t,error.code,importer.Error_Code.Not_Found)
}

@(test)
a_masked_texture_name_starts_with_a_brace :: proc(t:^testing.T) {
    folder:=temp_folder("masked")
    defer os.remove_all(folder)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"{\n\"classname\" \"worldspawn\"\n")
    cube_brush(&b,{0,0,0},"{glass")
    cube_brush(&b,{64,0,0},"skip")
    cube_brush(&b,{128,0,0},"sky")
    strings.write_string(&b,"}\n")
    path:=write_text(folder,"masked.map",strings.to_string(b))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,triangle_count(&model.meshes[0]),12)
    testing.expect_value(t,len(model.materials),1)
    testing.expect_value(t,model.materials[0].name,"{glass")
    testing.expect_value(t,model.materials[0].info.alpha_mode,.Mask)
    // skip y sky no se dibujan: ni material ni aviso de textura faltante
    for warning in model.warnings {
        testing.expect(t,!strings.contains(warning,"skip"),warning)
        testing.expect(t,!strings.contains(warning,"sky"),warning)
    }
}

@(test)
a_map_beyond_the_slot_limit_of_a_mesh_is_split :: proc(t:^testing.T) {
    folder:=temp_folder("slots")
    defer os.remove_all(folder)
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"{\n\"classname\" \"worldspawn\"\n")
    for i in 0..<40 {
        name:=fmt.tprintf("tex%d",i)
        cube_brush(&b,{i*64,0,0},name)
    }
    strings.write_string(&b,"}\n")
    path:=write_text(folder,"many.map",strings.to_string(b))
    model,ok:=import_ok(t,path)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect(t,len(model.meshes)>1,"40 texturas no entran en un mesh de 32 slots")
    testing.expect_value(t,len(model.materials),40)
    triangles:=0
    for &mesh in model.meshes {
        triangles+=triangle_count(&mesh)
        testing.expect(t,len(mesh.slots)<=32,"cada mesh respeta el tope de slots")
    }
    testing.expect_value(t,triangles,40*12)
}
