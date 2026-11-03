package valve220_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-valve220-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// A cube of 64 units with a crate texture whose image is not there.
CUBE_MAP :: `{
"classname" "worldspawn"
"mapversion" "220"
{
( 0 0 0 ) ( 0 64 0 ) ( 0 0 64 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 64 0 0 ) ( 64 0 64 ) ( 64 64 0 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 0 0 ) ( 0 0 64 ) ( 64 0 0 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 64 0 ) ( 64 64 0 ) ( 0 64 64 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 0 0 ) ( 64 0 0 ) ( 0 64 0 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1
( 0 0 64 ) ( 0 64 64 ) ( 64 0 64 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1
}
}
`

@(test)
the_format_the_plugin_gives_imports_a_map :: proc(t:^testing.T) {
    folder:=temp_folder("cube")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/cube.map",folder)
    testing.expect(t,os.write_entire_file(path,transmute([]u8)string(CUBE_MAP))==nil)
    formats:=[?]importer.Format{valve220_format_default().provider.format}
    model,error:=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    triangles:=0
    for mesh in model.meshes {triangles+=len(mesh.indices)/3}
    testing.expect_value(t,triangles,12)
    testing.expect(t,len(model.materials)==1 && model.materials[0].name=="crate","one material named after the texture")
}
