# Builds compare.html: the mockup's WebGL shader, taken verbatim from
# mockup/launcher.html, on the same striped cover the Metal tests use, next to
# the Metal frame. Serve the folder over http and open compare.html; the page's
# console check in evidence.md reads both back and compares them pixel by pixel.
#
#   python3 reveal-compare.py <repo> <folder>   (with reveal-frame-50.png in <folder>)
import pathlib
import re
import shutil
import sys

repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
page = (repo / "mockup/launcher.html").read_text()
vs = re.search(r"const FX_VS = `(.*?)`;", page, re.S).group(1)
fs = re.search(r"const FX_FS = `(.*?)`;", page, re.S).group(1)
shutil.copyfile(pathlib.Path(__file__).with_name("reveal-frame-50.png"), out / "metal-50.png")
html = """<!doctype html><html><body style="margin:0;background:#222;display:flex;gap:20px;padding:20px">
<div><canvas id=c width=400 height=600></canvas><div style="color:#fff;font:14px sans-serif">WebGL (mockup shader)</div></div>
<div><img src="metal-50.png" width=400 height=600><div style="color:#fff;font:14px sans-serif">Metal (Cartouche)</div></div>
<script>
const src=document.createElement('canvas');src.width=300;src.height=450;const x=src.getContext('2d');
function hsv(h,s,v){let f=(n,k=(n+h*6)%6)=>v-v*s*Math.max(Math.min(k,4-k,1),0);return [f(5)*255,f(3)*255,f(1)*255];}
for(let i=0;i<300;i++)for(let b=0;b<9;b++){const c=hsv(i/300,.8,b%2==0?.85:.6);x.fillStyle=`rgb(${c[0]|0},${c[1]|0},${c[2]|0})`;x.fillRect(i,b*50,1,51);}
const gl=document.getElementById('c').getContext('webgl',{premultipliedAlpha:false,preserveDrawingBuffer:true});
const sh=(t,s)=>{const o=gl.createShader(t);gl.shaderSource(o,s);gl.compileShader(o);return o};
const p=gl.createProgram();gl.attachShader(p,sh(gl.VERTEX_SHADER,`VS`));gl.attachShader(p,sh(gl.FRAGMENT_SHADER,`FS`));gl.linkProgram(p);gl.useProgram(p);
gl.bindBuffer(gl.ARRAY_BUFFER,gl.createBuffer());gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,1,1]),gl.STATIC_DRAW);
const a=gl.getAttribLocation(p,'a');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);
const tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,src);
[gl.TEXTURE_WRAP_S,gl.TEXTURE_WRAP_T].forEach(k=>gl.texParameteri(gl.TEXTURE_2D,k,gl.CLAMP_TO_EDGE));gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
const u=k=>gl.getUniformLocation(p,k);gl.viewport(0,0,400,600);
gl.uniform1f(u('P'),.5);gl.uniform1f(u('t'),1.3);gl.uniform1f(u('F'),0);gl.uniform1f(u('M'),1);gl.uniform2f(u('R'),400,600);gl.drawArrays(gl.TRIANGLE_STRIP,0,4);
</script></body></html>"""
(out / "compare.html").write_text(html.replace("`VS`", "`" + vs + "`").replace("`FS`", "`" + fs + "`"))
