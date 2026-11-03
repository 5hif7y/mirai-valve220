# valve220: Valve 220 maps for Mirai

A plugin for the Mirai engine editor that imports `.map` files in the Valve 220 dialect, the one
TrenchBroom, J.A.C.K. and the Hammer of GoldSrc write. Each brush becomes geometry of a static mesh,
with its collider and its materials.

## Install

From the catalog, in the folder of a Mirai project:

```sh
mirai plugin add valve220
```

Then import a `.map` from the editor: drop it on the content browser or use Import. Like every
format of a plugin, it imports in the editor and through its API, not with `mirai import`.

## What it reads

- **Entities** and their `"key" "value"` pairs; **brushes** as the intersection of the planes of their
  faces, each face given by three points, a texture and its Valve 220 axes
  (`[ ux uy uz shift ] [ vx vy vz shift ] rotation scale_x scale_y`).
- **Meshes:** the brushes of `worldspawn`, `func_group` and `func_detail` become one mesh named after
  the map; every other entity with brushes, a mesh of its own. A map past the slot limit of a mesh is
  split into several.
- **Materials:** one per texture name. The image is `textures/<name>.png` beside the map; a name that
  starts with `{` (GoldSrc masked textures) imports with alpha cutout. A texture without an image is a
  grey material and a warning.
- **Not drawn:** faces textured `skip`, `nodraw`, `caulk` and `sky`.
- **Errors:** a brush without volume and a face without area are skipped and counted in a warning; a
  file that is not a map fails with the line where it stopped.
- **Units:** 32 map units to the meter, Z up turned to Y up.

Entities without brushes (spawns, lights, triggers' logic) are not interpreted: they stay in the file
for a game to read.

## For other plugins

- `editor/mapfile` is the model of a map: entities, brushes and sides, read from and written as Valve
  220 (`map_write`), with the plane math. `map_convert`, `bsp_decompile` and `map_agent` build on it.
- `editor/loader` exports `read_text(reader, text, images)`: a converter hands it the Valve 220 it made
  and the texels of the textures its source keeps (a BSP, a WAD), and no file is written in between.

## Tests

With `mirai test plugins/valve220/editor/loader` in a project that has the plugin. The maps of the
tests are written by the tests themselves.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
