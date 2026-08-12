import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
def trydump(obj, label):
    for m in ["get_text", "text", "to_string", "ToString", "get_lines", "lines"]:
        try:
            v = getattr(obj, m)
            if callable(v): v = v()
            p("  [" + label + " via " + m + "]:")
            p(v)
            return
        except Exception as e:
            pass
    p("  [" + label + ": no accessor worked]")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\TS_PLC_TEST.project")
    app = proj.active_application
    pou = None
    for k in app.get_children(False):
        if k.get_name() == "MCP_TestPRG": pou = k
    p("POU FOUND: " + str(pou is not None))
    td = pou.textual_declaration
    ti = pou.textual_implementation
    p("decl obj type: " + str(type(td)))
    p("===== DECLARATION =====")
    trydump(td, "decl")
    p("===== IMPLEMENTATION =====")
    trydump(ti, "impl")
    p("READ_OK")
except Exception as e:
    p("READ_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
