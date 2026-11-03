package valve220_editor

import "mirai:editor"
import loader "project:plugins/valve220/editor/loader"

// Valve 220 .map in the import of the editor: the dialect TrenchBroom writes,
// its brushes to static meshes with their colliders and materials
// (loader/loader.odin). The model of a map, to read and write one, is
// mapfile/: the other map plugins build on it.

@(storage)
Valve220_Format :: struct {provider:editor.Import_Format_Provider}

valve220_format_default :: proc() -> Valve220_Format {
    return {provider={format=loader.FORMAT}}
}
