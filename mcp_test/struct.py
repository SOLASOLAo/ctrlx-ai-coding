import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\AI_Only_Test.project")
    p("PROJECT TOP LEVEL:")
    for k in proj.get_children(False):
        try: p("  - " + k.get_name())
        except: p("  - ?")
    app = proj.active_application
    p("APP CHILDREN:")
    for k in app.get_children(False):
        try: p("  - " + k.get_name())
        except: p("  - ?")
    p("STRUCT_DONE")
except Exception as e:
    p("STRUCT_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
