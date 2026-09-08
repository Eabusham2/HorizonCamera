#!/usr/bin/env python3
from pathlib import Path
import json,math,struct,zlib
root=Path(__file__).resolve().parent.parent/'App/Assets.xcassets'
out=root/'AppIcon.appiconset';out.mkdir(parents=True,exist_ok=True)
rows=[]
for y in range(1024):
    row=bytearray([0])
    for x in range(1024):
        t=(x+y)/2048;c=(int(12+9*t),int(22+15*t),int(35+23*t));d=math.hypot(x-512,y-512)
        if abs(d-298)<14:c=(58,88,107)
        if abs(d-219)<10:c=(128,171,188)
        if 205<x<819 and abs(y-512)<12:c=(255,211,71)
        if abs(x-512)<10 and 427<y<597:c=(255,211,71)
        if d<25:c=(255,230,127)
        for cx,cy,sx,sy in [(192,192,1,1),(832,192,-1,1),(192,832,1,-1),(832,832,-1,-1)]:
            if (abs(y-cy)<10 and 0<=(x-cx)*sx<100) or (abs(x-cx)<10 and 0<=(y-cy)*sy<100):c=(225,239,242)
        row.extend(c)
    rows.append(bytes(row))
def chunk(k,d):return struct.pack('!I',len(d))+k+d+struct.pack('!I',zlib.crc32(k+d)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',1024,1024,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows),9))+chunk(b'IEND',b'')
(out/'AppIcon.png').write_bytes(png)
(out/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2)+'\n')
(root/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
