#!/usr/bin/env python3
"""Check actual primary-display screenshots taken before native pop completion."""
import json
import pathlib
import sys
from PIL import Image

work=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/Volumes/Wand/Developer/ios/live-native-back')
records=json.loads((work/'held-frame-captures.json').read_text())
expected={(mode,source,target,revision) for mode in ['system-regular','system-compact','hidden'] for source,target in [('detail','parent'),('parent','list')] for revision in [1,2]}
observed=set();results=[];actual=[]
for r in records:
    if r.get('mode')=='installed':
        assert r['actualInstalledService'] and r['screenshotExit']==0 and not r['endedBeforeCapture'] and not r['endedDuringCapture'],r
        assert pathlib.Path(r['image']).is_file()
        actual.append({'stage':r['stage'],'image':r['image']})
        continue
    key=(r['mode'],r['from'],r['to'],r['revision'])
    assert key in expected,key
    assert r['nativeInteractive'] and r['identity'] and r['routeStable'],r
    assert r['screenshotExit']==0 and not r['endedBeforeCapture'] and not r['endedDuringCapture'],r
    im=Image.open(r['image']).convert('RGB');im.thumbnail((400,600))
    pixels=list(im.getdata());count=len(pixels)
    red=sum(a>180 and a>b+70 and a>c+70 for a,b,c in pixels)/count
    blue=sum(c>150 and c>a+65 and c>b+30 for a,b,c in pixels)/count
    green=sum(b>150 and b>a+35 and b>c+20 for a,b,c in pixels)/count
    yellow=sum(a>180 and b>180 and c<150 for a,b,c in pixels)/count
    cyan=sum(b>180 and c>180 and a<180 for a,b,c in pixels)/count
    if r['from']=='detail':assert red>0.03 and blue>0.03,(key,red,blue)
    else:assert green>0.03 and blue>0.03,(key,green,blue)
    changed=yellow if r['revision']%2 else cyan
    assert changed>0.0005,('Changed native label is not visible during the held swipe',key,changed)
    observed.add(key);results.append({'key':key,'image':r['image'],'red':red,'blue':blue,'green':green,'yellow':yellow,'cyan':cyan})
assert observed==expected,('Missing held native frames',sorted(expected-observed))
if actual: assert {r['stage'] for r in actual}=={'cancel','complete'}
result={'ok':True,'count':len(results),'actualPrimaryDisplay':1,'frames':results,'installedConversationFrames':actual}
(work/'held-visual-verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps({'ok':True,'count':len(results)},indent=2))
