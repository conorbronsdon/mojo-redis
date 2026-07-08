#!/usr/bin/env python3
"""Render `mojo doc` JSON into a single self-contained HTML API reference.

`mojo doc` emits JSON, not HTML; this turns that JSON into a searchable,
theme-aware, dependency-free page. Reusable across the pure-Mojo suite — it
reads the package name/version out of the JSON, nothing is hardcoded.

    mojo doc -o docs/api.json -I src src/<pkg>
    python3 docs/render_api.py docs/api.json docs/api.html
"""
import html
import json
import os
import sys


def esc(s):
    return html.escape(s or "")


def code(s):
    return f'<code>{esc(s)}</code>'


def render_overload(o):
    sig = o.get("signature", "")
    doc = o.get("summary") or o.get("description") or ""
    raises = o.get("raisesDoc") or ""
    parts = [f'<div class="sig">{esc(sig)}</div>']
    if doc:
        parts.append(f'<p class="doc">{esc(doc)}</p>')
    if raises:
        parts.append(f'<p class="raises"><span>raises</span> {esc(raises)}</p>')
    return "".join(parts)


def render_function(f):
    name = f.get("name", "")
    body = "".join(render_overload(o) for o in f.get("overloads", []))
    return (f'<div class="item" data-name="{esc(name.lower())}">'
            f'<h4>{esc(name)}<span class="kind">fn</span></h4>{body}</div>')


def render_field(fl):
    name = fl.get("name", "")
    typ = fl.get("type", "") or fl.get("signature", "")
    doc = fl.get("summary") or fl.get("description") or ""
    d = f' — {esc(doc)}' if doc else ""
    label = f'{code(name)}: {code(typ)}' if typ else code(name)
    return f'<li>{label}{d}</li>'


def render_struct(s):
    name = s.get("name", "")
    summary = s.get("summary") or s.get("description") or ""
    traits = s.get("parentTraits") or []
    fields = s.get("fields", [])
    methods = s.get("functions", [])
    out = [f'<div class="item struct" data-name="{esc(name.lower())}">']
    out.append(f'<h3>{esc(name)}<span class="kind">struct</span></h3>')
    if traits:
        names = [t.get("name", "") if isinstance(t, dict) else str(t) for t in traits]
        out.append('<p class="traits">' + " · ".join(code(n) for n in names if n) + "</p>")
    if summary:
        out.append(f'<p class="doc">{esc(summary)}</p>')
    if fields:
        out.append('<div class="sub">Fields</div><ul class="fields">')
        out.extend(render_field(f) for f in fields)
        out.append("</ul>")
    if methods:
        out.append('<div class="sub">Methods</div>')
        out.extend(render_function(m) for m in methods)
    out.append("</div>")
    return "".join(out)


def render_alias(a):
    name = a.get("name", "")
    sig = a.get("signature", "")
    doc = a.get("summary") or a.get("description") or ""
    d = f' — {esc(doc)}' if doc else ""
    return f'<li>{code(name)} = {code(sig)}{d}</li>' if sig else f'<li>{code(name)}{d}</li>'


def render_module(m):
    name = m.get("name", "")
    summary = m.get("summary") or m.get("description") or ""
    aliases = m.get("aliases", [])
    functions = m.get("functions", [])
    structs = m.get("structs", [])
    if not (aliases or functions or structs):
        return ""
    out = [f'<section class="module"><h2 id="{esc(name)}">{esc(name)}</h2>']
    if summary:
        out.append(f'<p class="doc">{esc(summary)}</p>')
    if aliases:
        out.append('<div class="sub">Aliases</div><ul class="aliases">')
        out.extend(render_alias(a) for a in aliases)
        out.append("</ul>")
    if structs:
        out.extend(render_struct(s) for s in structs)
    if functions:
        out.append('<div class="sub">Functions</div>')
        out.extend(render_function(f) for f in functions)
    out.append("</section>")
    return "".join(out)


CSS = """
:root{color-scheme:light dark;--bg:#fcfcfb;--fg:#0b0b0b;--muted:#57564f;--panel:#f3f3ef;--border:rgba(0,0,0,.1);--accent:#2a78d6;--code:#0b7285}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--panel:#161b22;--border:rgba(255,255,255,.1);--accent:#57c5bb;--code:#7ee0d6}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:1.9rem;margin:0 0 4px}.ver{color:var(--muted);margin:0 0 20px}
code{font-family:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85em;color:var(--code)}
#q{width:100%;padding:10px 12px;border:1px solid var(--border);border-radius:8px;background:var(--panel);color:var(--fg);font-size:1rem;margin-bottom:24px}
.module{border-top:1px solid var(--border);padding-top:8px;margin-top:24px}
h2{font-size:1.3rem;color:var(--accent)}
.item{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 16px;margin:12px 0}
.item h3,.item h4{margin:0 0 8px;font-size:1.05rem}
.kind{font-size:.7rem;font-weight:600;color:var(--muted);background:var(--bg);border:1px solid var(--border);border-radius:5px;padding:1px 6px;margin-left:8px;vertical-align:middle}
.sig{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:.82rem;background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:8px 10px;overflow-x:auto;white-space:pre;margin:6px 0}
.doc{color:var(--fg);margin:6px 0}.sub{font-size:.75rem;letter-spacing:.05em;text-transform:uppercase;color:var(--muted);margin:14px 0 4px}
.traits{color:var(--muted);margin:2px 0 8px}.raises{color:var(--muted);font-size:.9em;margin:4px 0}.raises span{color:#d03b3b;font-weight:600}
ul{margin:4px 0;padding-left:20px}li{margin:3px 0}.hidden{display:none}
footer{margin-top:40px;color:var(--muted);font-size:.85rem;border-top:1px solid var(--border);padding-top:16px}
a{color:var(--accent)}
"""

JS = """
const q=document.getElementById('q');
q.addEventListener('input',()=>{const v=q.value.toLowerCase();
document.querySelectorAll('.item').forEach(el=>{
 el.classList.toggle('hidden', v && !(el.dataset.name||'').includes(v) && !el.textContent.toLowerCase().includes(v));});
document.querySelectorAll('.module').forEach(m=>{
 const any=[...m.querySelectorAll('.item')].some(i=>!i.classList.contains('hidden'));
 m.style.display=any||!v?'':'none';});});
"""


def main():
    src, out = sys.argv[1], sys.argv[2]
    d = json.load(open(src))
    decl = d.get("decl", {})
    pkg = decl.get("name", "package")
    version = d.get("version", "")
    summary = decl.get("summary") or decl.get("description") or ""
    if os.path.dirname(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
    modules = "".join(render_module(m) for m in decl.get("modules", []))
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(pkg)} — API reference</title><style>{CSS}</style></head><body><div class="wrap">
<h1>{esc(pkg)}</h1><p class="ver">API reference{f' · {esc(version)}' if version else ''}</p>
{f'<p class="doc">{esc(summary)}</p>' if summary else ''}
<input id="q" type="search" placeholder="Filter symbols…" autocomplete="off">
{modules}
<footer>Generated from <code>mojo doc</code> JSON by <code>docs/render_api.py</code>. No hand-written HTML.</footer>
</div><script>{JS}</script></body></html>"""
    open(out, "w").write(page)
    print(f"wrote {out} ({len(page)} bytes)")


if __name__ == "__main__":
    main()
