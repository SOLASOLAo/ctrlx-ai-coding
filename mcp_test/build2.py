import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\AI_Only_Test.project")
    app = proj.active_application
    p("Building: " + app.get_name())
    app.build()
    p("BUILD_DONE")
except Exception as e:
    p("BUILD_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
