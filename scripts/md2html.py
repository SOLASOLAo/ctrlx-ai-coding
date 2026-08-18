# md2html.py - regenerate docs/ctrlX_AI_project_baseline.html from the MD source of truth
import io, os, sys, markdown

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO_ROOT, "docs", "ctrlX_AI_project_baseline.md")
DST = os.path.join(REPO_ROOT, "docs", "ctrlX_AI_project_baseline.html")

with io.open(SRC, "r", encoding="utf-8-sig") as f:
    md_text = f.read()

body = markdown.markdown(md_text, extensions=["tables", "fenced_code", "toc"])

TEMPLATE = u"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ctrlX AI 项目基线记录</title>
<style>
  :root { --fg:#1a2332; --muted:#5c6b7f; --accent:#0b6e4f; --line:#dde4ec; --code-bg:#f4f6f9; }
  * { box-sizing: border-box; }
  body { font-family: "Segoe UI", "Microsoft YaHei", sans-serif; color: var(--fg);
         max-width: 980px; margin: 0 auto; padding: 32px 28px 80px; line-height: 1.65; }
  h1 { border-bottom: 3px solid var(--accent); padding-bottom: 10px; }
  h2 { margin-top: 2em; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
  h3 { margin-top: 1.5em; color: #234; }
  blockquote { border-left: 4px solid var(--accent); margin: 1em 0; padding: 6px 16px;
               background: #f0f7f4; color: var(--muted); }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: 14px; }
  th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #eef2f7; }
  code { background: var(--code-bg); padding: 2px 5px; border-radius: 4px;
         font-family: Consolas, "Courier New", monospace; font-size: 0.92em; }
  pre { background: #0f172a; color: #e2e8f0; padding: 14px 16px; border-radius: 8px;
        overflow-x: auto; line-height: 1.5; }
  pre code { background: none; color: inherit; padding: 0; }
  hr { border: none; border-top: 1px solid var(--line); margin: 2.2em 0; }
</style>
</head>
<body>
__BODY__
</body>
</html>
"""
html = TEMPLATE.replace("__BODY__", body)

with io.open(DST, "w", encoding="utf-8") as f:
    f.write(html)
print("OK ->", DST, len(html), "chars")
