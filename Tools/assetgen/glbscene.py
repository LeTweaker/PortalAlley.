import json, struct, io
import numpy as np
from PIL import Image
def load(path):
    b=open(path,'rb').read()
    l,=struct.unpack_from('<I',b,12); g=json.loads(b[20:20+l]); binoff=20+l+8
    def acc(i):
        a=g['accessors'][i]; bv=g['bufferViews'][a['bufferView']]
        n={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4}[a['type']]; dt={5126:np.float32,5125:np.uint32,5123:np.uint16,5121:np.uint8}[a['componentType']]
        st=bv.get('byteStride',0); off=binoff+bv.get('byteOffset',0)+a.get('byteOffset',0)
        if st and st!=n*np.dtype(dt).itemsize:
            raw=np.frombuffer(b,np.uint8,a['count']*st,off).reshape(a['count'],st)[:, :n*np.dtype(dt).itemsize].copy()
            return raw.view(dt).reshape(a['count'],n)
        x=np.frombuffer(b,dt,a['count']*n,off)
        return x.reshape(a['count'],n) if n>1 else x
    def img(i):
        bv=g['bufferViews'][g['images'][i]['bufferView']]
        return Image.open(io.BytesIO(b[binoff+bv.get('byteOffset',0):binoff+bv.get('byteOffset',0)+bv['byteLength']])).convert('RGB')
    def M(n):
        if 'matrix' in n: return np.array(n['matrix'],float).reshape(4,4).T
        m=np.eye(4)
        if 'rotation' in n:
            x,y,z,w=n['rotation']; m[:3,:3]=[[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]]
        if 'scale' in n: m[:3,:3]=m[:3,:3]@np.diag(n['scale'])
        if 'translation' in n: m[:3,3]=n['translation']
        return m
    prims=[]
    def walk(i,P):
        n=g['nodes'][i]; W=P@M(n)
        if 'mesh' in n:
            for p in g['meshes'][n['mesh']]['primitives']:
                pos=acc(p['attributes']['POSITION']).astype(float); nrm=acc(p['attributes']['NORMAL']).astype(float) if 'NORMAL' in p['attributes'] else None
                uv=acc(p['attributes']['TEXCOORD_0']).astype(float) if 'TEXCOORD_0' in p['attributes'] else None
                idx=acc(p['indices']).astype(np.int64) if 'indices' in p else np.arange(len(pos))
                pos=pos@W[:3,:3].T+W[:3,3]
                if nrm is not None:
                    nrm=nrm@np.linalg.inv(W[:3,:3]).T; nrm/=np.linalg.norm(nrm,axis=1,keepdims=True)+1e-12
                if np.linalg.det(W[:3,:3])<0: idx=idx.reshape(-1,3)[:,[0,2,1]].reshape(-1)
                prims.append(dict(pos=pos,nrm=nrm,uv=uv,idx=idx,mat=p.get('material')))
        for c in n.get('children',[]): walk(c,W)
    for r in g['scenes'][g.get('scene',0)]['nodes']: walk(r,np.eye(4))
    texs=[img(i) for i in range(len(g.get('images',[])))]
    mats=[]
    for mt in g.get('materials',[]):
        t=mt.get('pbrMetallicRoughness',{}).get('baseColorTexture')
        mats.append(g['textures'][t['index']]['source'] if t else None)
    return g,prims,texs,mats
