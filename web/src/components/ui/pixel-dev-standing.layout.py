import sys
sys.path.insert(0, "/tmp/sprite")
from png import write_png

W, H = 26, 40

PAL = {
    "O": (0x11,0x0f,0x0d,255),
    "K": (0x3c,0x2b,0x1f,255), "k": (0x57,0x40,0x2d,255),
    "S": (0xf2,0xc3,0x9d,255), "s": (0xd4,0x9e,0x76,255),
    "G": (0x1b,0x1c,0x21,255), "L": (0xf5,0xa5,0x24,255), "E": (0x20,0x15,0x08,255),
    "m": (0x9e,0x55,0x41,255),
    "A": (0xf8,0xf9,0xfb,255),
    "T": (0x3c,0x47,0x59,255), "d": (0x2b,0x33,0x41,255),
    "P": (0x4a,0xd6,0x6a,255),
    "J": (0x23,0x2a,0x36,255),                 # trousers, darker than the shirt
    "B": (0x22,0x24,0x29,255),                 # shoes
    ".": (0,0,0,0),
}

def blank(): return [["." for _ in range(W)] for _ in range(H)]
def rect(g,x0,x1,y0,y1,ch):
    for y in range(y0,y1+1):
        for x in range(x0,x1+1):
            if 0<=x<W and 0<=y<H: g[y][x]=ch
def px(g,x,y,ch):
    if 0<=x<W and 0<=y<H: g[y][x]=ch

def draw(pose):
    g = blank()
    # crouch offset: the whole upper body sits lower while rising from the chair
    dy  = {"sit":5, "rising":2, "standing":0, "reachUp":0, "backArch":1}[pose]
    lean = {"sit":0, "rising":1, "standing":0, "reachUp":0, "backArch":-1}[pose]

    # ---- head ----
    rect(g, 8+lean, 17+lean, 3+dy, 4+dy, "K")
    rect(g, 7+lean, 18+lean, 5+dy, 5+dy, "K")
    rect(g, 9+lean, 15+lean, 2+dy, 2+dy, "k")
    rect(g, 8+lean, 17+lean, 6+dy, 12+dy, "S")
    rect(g, 7+lean,  7+lean, 6+dy, 8+dy, "K")
    rect(g,18+lean, 18+lean, 6+dy, 8+dy, "K")
    px(g, 17+lean, 12+dy, "s")
    # earbuds
    px(g, 6+lean, 8+dy, "A"); px(g, 19+lean, 8+dy, "A")
    px(g, 6+lean, 9+dy, "A"); px(g, 19+lean, 9+dy, "A")
    # glasses with eyes behind them
    rect(g, 8+lean, 11+lean, 8+dy, 8+dy, "G"); rect(g, 14+lean, 17+lean, 8+dy, 8+dy, "G")
    px(g, 8+lean, 9+dy, "G"); rect(g, 9+lean, 10+lean, 9+dy, 9+dy, "L"); px(g, 11+lean, 9+dy, "G")
    px(g,14+lean, 9+dy, "G"); rect(g,15+lean, 16+lean, 9+dy, 9+dy, "L"); px(g, 17+lean, 9+dy, "G")
    px(g, 12+lean, 9+dy, "G"); px(g, 13+lean, 9+dy, "G")
    px(g, 10+lean, 9+dy, "E"); px(g, 15+lean, 9+dy, "E")
    rect(g, 11+lean, 14+lean, 11+dy, 11+dy, "m")

    # ---- neck & torso ----
    rect(g, 11+lean, 14+lean, 13+dy, 13+dy, "S")
    rect(g,  8+lean, 17+lean, 14+dy, 24+dy, "T")
    rect(g,  8+lean,  9+lean, 14+dy, 24+dy, "d")
    # a small </> so the shirt still reads as a code shirt at this size
    # "< >" in 5 rows. Bolder and legible where a full </> turns to mush.
    lt = [12, 11, 10, 11, 12]
    gt = [14, 15, 16, 15, 14]
    for i in range(5):
        y = 18 + dy + i
        px(g, lt[i]+lean, y, "P")
        px(g, gt[i]+lean, y, "P")

    # ---- arms ----
    if pose == "reachUp":
        rect(g, 5+lean, 7+lean, 1+dy, 15+dy, "T")
        rect(g,18+lean,20+lean, 1+dy, 15+dy, "T")
        rect(g, 5+lean, 7+lean, -1+dy, 0+dy, "S")
        rect(g,18+lean,20+lean, -1+dy, 0+dy, "S")
    elif pose == "backArch":
        # hands to the small of the back, elbows out. The actual stretch.
        # arms up and splayed outward, torso tipped back: the shape people
        # actually make when they unfold at a desk
        rect(g, 4+lean, 6+lean,  4+dy, 15+dy, "T")
        rect(g,19+lean,21+lean,  4+dy, 15+dy, "T")
        rect(g, 3+lean, 5+lean,  2+dy,  3+dy, "S")
        rect(g,20+lean,22+lean,  2+dy,  3+dy, "S")
    else:
        rect(g, 5+lean, 7+lean, 15+dy, 23+dy, "T")
        rect(g,18+lean,20+lean, 15+dy, 23+dy, "T")
        rect(g, 8+lean, 8+lean, 15+dy, 23+dy, "O")   # seam, arm vs torso
        rect(g,17+lean,17+lean, 15+dy, 23+dy, "O")
        rect(g, 5+lean, 7+lean, 24+dy, 25+dy, "S")
        rect(g,18+lean,20+lean, 24+dy, 25+dy, "S")

    # ---- legs ----
    if pose in ("sit", "rising"):
        knee = 27+dy
        rect(g,  8, 11, 25+dy, knee, "J"); rect(g, 14, 17, 25+dy, knee, "J")
        rect(g,  8, 11, knee, knee+2, "J"); rect(g, 14, 17, knee, knee+2, "J")
        rect(g,  9, 11, knee+3, 36, "J");   rect(g, 14, 16, knee+3, 36, "J")
    else:
        rect(g,  9, 11, 25+dy, 36, "J"); rect(g, 14, 16, 25+dy, 36, "J")
    rect(g, 8, 12, 37, 38, "B"); rect(g, 13, 17, 37, 38, "B")
    return g

def outline(g):
    out=[r[:] for r in g]
    for y in range(H):
        for x in range(W):
            if g[y][x]!=".": continue
            for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
                nx,ny=x+dx,y+dy
                if 0<=nx<W and 0<=ny<H and g[ny][nx] not in (".","O"):
                    out[y][x]="O"; break
    return out

POSES = ["sit","rising","standing","reachUp","backArch"]

if __name__=="__main__":
    grids=[outline(draw(p)) for p in POSES]
    strip=[[(0,0,0,0)]*(W*len(POSES)) for _ in range(H)]
    for gi,g in enumerate(grids):
        for y in range(H):
            for x in range(W): strip[y][gi*W+x]=PAL[g[y][x]]
    write_png("/tmp/sprite/stand.png", strip, W*len(POSES), H, scale=7)
    print("ok", [len(["".join(r) for r in g]) for g in grids])
