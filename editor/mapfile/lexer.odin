package valve220_mapfile

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// The text maps of other editors: the .vmf of Hammer for Source, and the .map
// of Doom 3 and Quake 4 (brushDef3). Both keep the brushes of the mapper, so
// they convert side by side; what Valve 220 has no place for (displacements,
// patches) is counted in a warning and left out.

DOOM3_TEXTURE_SIZE :: 128 // texels a texture of Doom 3 is taken to measure, which the .map does not say

Text_Lexer :: struct {
    text:string,
    at:int,
    line:int,
}

// The next token: a quoted string without its quotes, one of ( ) { } [ ], or a run of other characters.
text_token :: proc(l:^Text_Lexer) -> (token:string,quoted,ok:bool) {
    for l.at<len(l.text) {
        c:=l.text[l.at]
        if c=='\n' {l.line+=1;l.at+=1;continue}
        if c==' ' || c=='\t' || c=='\r' {l.at+=1;continue}
        if c=='/' && l.at+1<len(l.text) && l.text[l.at+1]=='/' {
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
        for l.at<len(l.text) && l.text[l.at]!='"' {l.at+=1}
        if l.at>=len(l.text) {return "",true,false}
        l.at+=1
        return l.text[start+1:l.at-1],true,true
    }
    if c=='(' || c==')' || c=='{' || c=='}' || c=='[' || c==']' {
        l.at+=1
        return l.text[start:l.at],false,true
    }
    for l.at<len(l.text) {
        b:=l.text[l.at]
        if b==' ' || b=='\t' || b=='\r' || b=='\n' || b=='(' || b==')' || b=='{' || b=='}' || b=='[' || b==']' || b=='"' {break}
        l.at+=1
    }
    return l.text[start:l.at],false,true
}

// The next run of characters up to a space: a texture name, which in GoldSrc
// may start with { (a masked texture).
text_word :: proc(l:^Text_Lexer) -> string {
    space :: proc(c:u8) -> bool {return c==' ' || c=='\t' || c=='\r' || c=='\n'}
    for l.at<len(l.text) && space(l.text[l.at]) {l.at+=1}
    start:=l.at
    for l.at<len(l.text) && !space(l.text[l.at]) {l.at+=1}
    return l.text[start:l.at]
}

text_numbers :: proc(text:string,out:[]f64) -> bool {
    clean,_:=strings.replace_all(text,"(","",context.temp_allocator)
    clean,_=strings.replace_all(clean,")","",context.temp_allocator)
    clean,_=strings.replace_all(clean,"[","",context.temp_allocator)
    clean,_=strings.replace_all(clean,"]","",context.temp_allocator)
    parts:=strings.fields(clean,context.temp_allocator)
    if len(parts)<len(out) {return false}
    for &o,i in out {
        v,ok:=strconv.parse_f64(parts[i])
        if !ok {return false}
        o=v
    }
    return true
}

// The plane through three points in the order of the .map: normal = (p0-p1)×(p2-p1).
plane_from_points :: proc(p:[3][3]f64) -> (plane:Plane,ok:bool) {
    n,length:=normalize(cross(p[0]-p[1],p[2]-p[1]))
    if length<1e-9 {return {},false}
    return {n,dot(n,p[0])},true
}
