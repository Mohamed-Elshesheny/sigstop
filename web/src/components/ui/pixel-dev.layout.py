import sys
sys.path.insert(0, "/tmp/sprite")
from png import write_png

W, H = 40, 42

PAL = {
    "O": (0x11, 0x0f, 0x0d, 255),
    "K": (0x3c, 0x2b, 0x1f, 255), "k": (0x57, 0x40, 0x2d, 255), "h": (0x78, 0x59, 0x3f, 255),
    "S": (0xf2, 0xc3, 0x9d, 255), "s": (0xd4, 0x9e, 0x76, 255),
    "G": (0x1b, 0x1c, 0x21, 255), "L": (0xf5, 0xa5, 0x24, 255), "W": (0xff, 0xdc, 0x95, 255),
    "E": (0x20, 0x15, 0x08, 255),                                  # pupil
    "m": (0x9e, 0x55, 0x41, 255),
    "A": (0xf8, 0xf9, 0xfb, 255), "a": (0xc9, 0xcd, 0xd3, 255),
    "T": (0x3c, 0x47, 0x59, 255), "d": (0x2b, 0x33, 0x41, 255),
    "P": (0x4a, 0xd6, 0x6a, 255),
    "M": (0xb8, 0xbe, 0xc6, 255), "n": (0x8e, 0x96, 0xa1, 255),    # macbook lid / shadow
    "c": (0x6e, 0x76, 0x82, 255),                                  # lid circle
    "U": (0xe8, 0x5d, 0x3a, 255), "u": (0xbf, 0x45, 0x27, 255),    # mug
    "V": (0xc8, 0xcf, 0xd8, 190),                                  # steam
    "D": (0x4a, 0x3d, 0x32, 255),
    ".": (0, 0, 0, 0),
}

def blank(): return [["." for _ in range(W)] for _ in range(H)]
def rect(g,x0,x1,y0,y1,ch):
    for y in range(y0,y1+1):
        for x in range(x0,x1+1):
            if 0<=x<W and 0<=y<H: g[y][x]=ch
def px(g,x,y,ch):
    if 0<=x<W and 0<=y<H: g[y][x]=ch

# A curved skull: explicit spans per row beat trying to rasterise an ellipse.
HEAD = {2:(14,24),3:(12,26),4:(11,27),5:(10,28),6:(10,28),7:(10,28),8:(10,28),
        9:(10,28),10:(10,28),11:(10,28),12:(10,28),13:(10,28),14:(10,28),
        15:(11,27),16:(12,26),17:(13,25),18:(15,23)}

def draw(pose="typingA", steam=0):
    g = blank()
    dy = 1 if pose=="slumped" else (1 if pose=="typingB" else 0)   # 1px bob while typing
    up = pose=="stretching"

    for y,(x0,x1) in HEAD.items():
        rect(g,x0,x1,y+dy,y+dy,"S")
        if y>=6: px(g,x1,y+dy,"s")               # screen lights the left, shadow right

    # hair: cap plus a part swept right
    for y,(x0,x1) in HEAD.items():
        if y<=7: rect(g,x0,x1,y+dy,y+dy,"K")
    rect(g,13,22,3+dy,3+dy,"k"); rect(g,15,20,2+dy,2+dy,"h")
    rect(g,16,28,7+dy,8+dy,"K")                  # fringe
    rect(g,10,12,8+dy,12+dy,"K"); rect(g,26,28,8+dy,12+dy,"K")   # sideburns

    # AirPods: bud then stem, 2px so they actually read
    for bx in (8,30):
        rect(g,bx,bx+1,10+dy,11+dy,"A")
        rect(g,bx,bx+1,12+dy,14+dy,"a" if bx==30 else "A")

    # glasses with EYES behind the lenses, a blank amber stare has no life in it
    gy=11+dy
    rect(g,11,16,gy,gy,"G");   rect(g,22,27,gy,gy,"G")
    px(g,11,gy+1,"G"); rect(g,12,15,gy+1,gy+2,"L"); px(g,16,gy+1,"G")
    px(g,22,gy+1,"G"); rect(g,23,26,gy+1,gy+2,"L"); px(g,27,gy+1,"G")
    px(g,11,gy+2,"G"); px(g,16,gy+2,"G"); px(g,22,gy+2,"G"); px(g,27,gy+2,"G")
    rect(g,11,16,gy+3,gy+3,"G"); rect(g,22,27,gy+3,gy+3,"G")
    rect(g,17,21,gy+1,gy+1,"G")                  # bridge
    px(g,12,gy+1,"W"); px(g,23,gy+1,"W")         # glint
    if pose!="slumped":
        rect(g,13,14,gy+1,gy+2,"E"); rect(g,24,25,gy+1,gy+2,"E")
    else:
        rect(g,13,14,gy+2,gy+2,"E"); rect(g,24,25,gy+2,gy+2,"E")   # lids lower

    # mouth: a short line with dimples, not a slab
    rect(g,17,21,16+dy,16+dy,"m"); px(g,16,16+dy,"s"); px(g,22,16+dy,"s")

    # neck
    rect(g,16,22,19+dy,20+dy,"S"); rect(g,16,22,19+dy,19+dy,"s")

    # shirt
    rect(g,12,26,21,21,"T"); rect(g,9,29,22,22,"T"); rect(g,7,31,23,33,"T")
    rect(g,7,9,23,33,"d"); rect(g,29,31,23,33,"d")

    # </> with 2px strokes so it reads as a glyph rather than confetti
    lt=[13,12,11,10,11,12,13]; sl=[22,21,20,19,18,17,16]; gt=[25,26,27,28,27,26,25]
    for i in range(7):
        y=24+i
        px(g,lt[i],y,"P"); px(g,sl[i],y,"P"); px(g,gt[i],y,"P")
        # thicken along the direction of travel, never across the gaps
        px(g,lt[i],y+1 if i<6 else y,"P"); px(g,gt[i],y+1 if i<6 else y,"P")

    # arms
    if up:
        # Arms rise FROM the shoulder and splay outward a little, so they read
        # as arms rather than two poles parked next to the head.
        for i, y in enumerate(range(22, 7, -1)):
            off = i // 5                      # drift out by a pixel every 5 rows
            rect(g, 5-off, 7-off, y, y, "T")
            rect(g, 31+off, 33+off, y, y, "T")
        rect(g, 2, 5, 5, 8, "S")              # fists
        rect(g, 33, 36, 5, 8, "S")
        px(g, 2, 5, "s"); px(g, 36, 5, "s")
    else:
        rect(g,5,7,24,31,"T"); rect(g,31,33,24,31,"T")

    # MacBook, lid toward us. No logo, just the circle, so it is a laptop and
    # not somebody's trademark.
    rect(g,6,32,32,39,"M")
    rect(g,6,32,39,39,"n")
    for y,(x0,x1) in {34:(18,20),35:(17,21),36:(17,21),37:(18,20)}.items():
        rect(g,x0,x1,y,y,"c")
    rect(g,4,34,40,40,"n")                       # base lip
    rect(g,0,39,41,41,"D")                       # desk edge

    # mug plus steam
    rect(g,34,38,33,33,"U")
    for y in (34,35,36,37):
        px(g,34,y,"U"); rect(g,35,37,y,y,"u"); px(g,38,y,"U")
    rect(g,34,38,38,38,"U"); px(g,39,35,"U"); px(g,39,36,"U")   # handle
    # steam rises from the mug mouth (x34..38, top at y33) and drifts
    for i in range(6):
        sy = 31 - i*2
        sx = 36 + (1 if (i+steam) % 3 == 0 else (-1 if (i+steam) % 3 == 1 else 0))
        px(g, sx, sy - (steam % 2), "V")
        if i < 3: px(g, sx+1, sy - (steam % 2), "V")

    return g

def outline(g):
    out=[r[:] for r in g]
    for y in range(H):
        for x in range(W):
            if g[y][x]!=".": continue
            for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
                nx,ny=x+dx,y+dy
                if 0<=nx<W and 0<=ny<H and g[ny][nx] not in (".","O","V"):
                    out[y][x]="O"; break
    return out

if __name__=="__main__":
    pose=sys.argv[1] if len(sys.argv)>1 else "typingA"
    steam=int(sys.argv[2]) if len(sys.argv)>2 and sys.argv[2].isdigit() else 0
    g=outline(draw(pose,steam)); rows=["".join(r) for r in g]
    assert all(len(r)==W for r in rows), [len(r) for r in rows]
    write_png(f"/tmp/sprite/{pose}.png",[[PAL[c] for c in r] for r in rows],W,H,scale=12)
    if "--ts" in sys.argv: print(",\n".join(f'  "{r}"' for r in rows))
