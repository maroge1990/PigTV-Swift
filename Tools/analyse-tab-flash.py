# Build 32: per-frame colour of a simulator recording, for the tab-switch flash.
#   xcrun simctl io <udid> recordVideo --codec=h264 out.mp4   (while TabFlashUITests runs; Ctrl-C to stop)
#   python3 Tools/analyse-tab-flash.py out.mp4
# Each line: frame, share of near-white grey cells, share of darker grey cells, mean luminance (32x18 grid).
import sys, subprocess
path = sys.argv[1]
W,H = 32,18
p = subprocess.run(["ffmpeg","-v","error","-i",path,"-fps_mode","passthrough","-vf",f"scale={W}:{H}:flags=area","-f","rawvideo","-pix_fmt","rgb24","-"],capture_output=True)
data = p.stdout; n = len(data)//(W*H*3)
prev=None
rows=[]
for i in range(n):
    f = data[i*W*H*3:(i+1)*W*H*3]
    white=black=0; tot=0
    for j in range(0,len(f),3):
        r,g,b=f[j],f[j+1],f[j+2]
        l=(0.2126*r+0.7152*g+0.0722*b)/255
        grey = max(r,g,b)-min(r,g,b)<24
        if l>0.85 and grey: white+=1
        if l<0.75 and grey: black+=1
        tot+=l
    rows.append((i, white/(W*H), black/(W*H), tot/(W*H)))
for r in rows:
    print("%d white=%.2f darkgrey=%.2f mean=%.2f"%r)
