import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json, sys
from common import *
SYS = ("You answer one classification question about a software task. "
 "The task is described inside <document> tags. " + DH +
 " Return a probability for every label; the probabilities must sum to 1.")
schema = {"type":"object","properties":{k:{"type":"number"} for k in LABELS},"required":list(LABELS),"additionalProperties":False}
def esc(s): return s.replace("<","&lt;").replace(">","&gt;")
rows=[]; lat=[]
for rep in range(2):
    for exp, st in TASKS:
        doc = esc(json.dumps(st))
        user = "Labels:\n" + "\n".join(f"- {k}: {v}" for k,v in LABELS.items()) + f"\n\n<document>{doc}</document>\n\nWhich class of software task does this describe?"
        body = {"model":"anthropic/claude-haiku-5.5","temperature":0,"max_tokens":300,
          "messages":[{"role":"system","content":SYS},{"role":"user","content":user}],
          "response_format":{"type":"json_schema","json_schema":{"name":"answer","strict":True,"schema":schema}},"usage":{"include":True}}
        code, ms, raw = post("https://openrouter.ai/api/v1/chat/completions", body, timeout=30)
        r={"exp":exp,"code":code,"ms":ms}
        if code==200:
            j=json.loads(raw); txt=j["choices"][0]["message"]["content"]; r["cost"]=j.get("usage",{}).get("cost"); r["model"]=j.get("model")
            try:
                p=json.loads(txt); r["p"]=p; r["choice"]=max(p,key=p.get); r["sum"]=sum(p.values()); lat.append(ms)
            except Exception as e: r["invalid"]=txt[:200]
        else: r["err"]=raw[:200].decode(errors="replace")
        rows.append(r); print(exp, code, round(ms), r.get("choice"), round(r.get("sum",0),3), r.get("invalid") or r.get("err") or "", flush=True)
ok=[r for r in rows if "p" in r]
print(f"n={len(rows)} ok={len(ok)} invalid={sum('invalid' in r for r in rows)} err={sum('err' in r for r in rows)} p50={pct(lat,.5):.0f} p95={pct(lat,.95):.0f} min={min(lat):.0f} max={max(lat):.0f} over1600={sum(x>1600 for x in lat)} correct={sum(r['choice']==r['exp'] for r in ok)} badsum={sum(abs(r['sum']-1)>0.02 for r in ok)} cost={sum(r.get('cost') or 0 for r in rows):.4f} models={set(r.get('model') for r in rows)}")
for r in ok: print(" ",r["exp"], "top", round(max(r["p"].values()),2))
json.dump(rows,open("frontier_out.json","w"),indent=1)
