import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json, sys
from common import *
URLS = {"typesafe":"https://api.typesafe.ai/v1/systemone","openrouter":"https://openrouter.ai/api/v1/systemone"}
out = {}
# spike 5: model ids
ids = ["jev-1.13.0","jev-1.13","jev-latest","typesafe/jev-1.13","typesafe/jev-1.13-20260917","typesafe/jev-1.13.0","typesafe/jev-latest","jev-1.13-20260917"]
for t,u in URLS.items():
    for m in ids:
        code, ms, raw = post(u, jev_body(m, TASKS[0][1]))
        try: j = json.loads(raw); res = j.get("model") if code==200 else str(j)[:120]
        except Exception: res = raw[:120]
        print(f"ids {t} {m!r} -> {code} {res}", flush=True)
# spike 6/8: latency
pin = {"typesafe": sys.argv[1], "openrouter": sys.argv[2]}
for t,u in URLS.items():
    lat=[]; errs=0; rows=[]
    for rep in range(5):
        for exp, st in TASKS:
            code, ms, raw = post(u, jev_body(pin[t], st))
            if code!=200: errs+=1; print("ERR",t,code,raw[:200]); continue
            j = json.loads(raw); a = j["answers"]["class"]; p = a.get("probabilities",{})
            lat.append(ms); rows.append({"exp":exp,"model":j.get("model"),"choice":a.get("choice"),"conf":a.get("confidence"),
              "top":max(p.values()) if p else None,"sum":sum(p.values()),"ties":sorted(p.values())[-1]==sorted(p.values())[-2] if len(p)>1 else False,
              "zero":all(v==0 for v in p.values()),"usage":j.get("usage"),"keys":sorted(j.keys()),"akeys":sorted(a.keys())})
    out[t]={"lat":lat,"errs":errs,"rows":rows}
    print(t, f"n={len(lat)} err={errs} p50={pct(lat,.5):.0f} p95={pct(lat,.95):.0f} min={min(lat):.0f} max={max(lat):.0f} mean={sum(lat)/len(lat):.0f} over1600={sum(x>1600 for x in lat)}", flush=True)
json.dump(out, open("jev_out.json","w"), indent=1)
