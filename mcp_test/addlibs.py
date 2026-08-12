import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\AI_Only_Test.project")
    app = proj.active_application
    p("APP: " + app.get_name())
    lm = None
    for k in app.get_children(False):
        if k.get_name() == "Library Manager": lm = k
    p("LM FOUND: " + str(lm is not None))
    for name in ["OpconBase", "OpconBaseCommonDef", "OpconFbpBase", "CXA_Base"]:
        try:
            res = lm.add_library(name)
            p("ADD OK: " + name + " -> " + str(res))
        except Exception as e:
            p("ADD FAIL: " + name + " -> " + repr(e))
    libs = lm.get_libraries()
    p("LIB COUNT AFTER: " + str(len(libs)))
    for lib in libs:
        try: p("  - " + str(lib))
        except: p("  - ?")
    proj.save()
    p("SAVED")
    p("ADDLIBS_DONE")
except Exception as e:
    p("ADDLIBS_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
