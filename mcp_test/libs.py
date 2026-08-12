import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\TS_PLC_TEST.project")
    app = proj.active_application
    lm = None
    for k in app.get_children(False):
        if k.get_name() == "Library Manager": lm = k
    libs = lm.get_libraries()
    p("LIB COUNT: " + str(len(libs)))
    i = 0
    for lib in libs:
        i += 1
        try: p(str(i) + ": " + str(lib))
        except Exception as e: p(str(i) + ": <unprintable: " + repr(e) + ">")
    p("LIBS_DONE")
except Exception as e:
    p("LIBS_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
