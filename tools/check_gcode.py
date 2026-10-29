import re,sys,math
g=open(sys.argv[1]).read().split('\n')
x=y=z=0.0; e_tot=0; ext_box=[1e9,1e9,-1e9,-1e9]; trav_box=[1e9,1e9,-1e9,-1e9]; zmin_ext=1e9; zmax_ext=0
bad=[]; layer=-1; layer_e={}; lastZ_layer=0; ext_moves=0; maxF=0; retr=0
in_exec=False
for i,l in enumerate(g):
    if l.startswith('; EXECUTABLE_BLOCK_START'): in_exec=True
    if l.startswith('; CHANGE_LAYER'): layer+=1
    if 'nan' in l.lower() and not l.startswith(';') : bad.append((i,l))
    c=l.split(';')[0].strip()
    if not c: continue
    m=re.match(r'G[01]\s(.*)',c)
    if not m: 
        if re.match(r'G28',c): pass
        continue
    d=dict((t[0],float(t[1:])) for t in m.group(1).split() if t[0] in 'XYZEF' and re.match(r'^-?[\d.]+$',t[1:]))
    nx=d.get('X',x); ny=d.get('Y',y); nz=d.get('Z',z); e=d.get('E',0)
    if 'F' in d: maxF=max(maxF,d['F'])
    if e>0 and ('X' in d or 'Y' in d) and layer>=0:
        ext_moves+=1; e_tot+=e; layer_e[layer]=layer_e.get(layer,0)+e
        ext_box=[min(ext_box[0],nx),min(ext_box[1],ny),max(ext_box[2],nx),max(ext_box[3],ny)]
        zmin_ext=min(zmin_ext,nz); zmax_ext=max(zmax_ext,nz)
        if nx<0 or ny<0 or nx>256 or ny>256: bad.append((i,'extrude off bed '+l))
        seglen=math.hypot(nx-x,ny-y)
        if seglen>0 and e/seglen>0.12: bad.append((i,'heavy extrusion %.3f mm/mm '%(e/seglen)+l))
    elif layer>=0 and ('X' in d or 'Y' in d):
        trav_box=[min(trav_box[0],nx),min(trav_box[1],ny),max(trav_box[2],nx),max(trav_box[3],ny)]
    x,y,z=nx,ny,nz
print('layers',layer+1,'extrusion moves',ext_moves,'E total %.1f mm'%e_tot)
print('extrude bbox',[round(v,2) for v in ext_box],'z range',zmin_ext,zmax_ext)
print('travel bbox (incl templates)',[round(v,2) for v in trav_box],'max F',maxF)
print('E per layer',[round(layer_e.get(k,0)) for k in range(layer+1)])
print('problems',len(bad)); [print(b) for b in bad[:12]]
