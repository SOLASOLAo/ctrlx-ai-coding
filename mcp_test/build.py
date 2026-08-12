import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    proj = se.projects.open(r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\TS_PLC_TEST.project")
    app = proj.active_application
    p("Building application: " + app.get_name())
    app.build()
    msgs = se.system.get_messages()
    p("MESSAGE COUNT: " + str(len(msgs)))
    nErr = 0; nWarn = 0
    for m in msgs:
        try:
            sev = str(m.severity)
            txt = str(m.text)
            src = str(m.sender)
            line = getattr(m, 'line', '')
            if 'error' in sev.lower(): nErr += 1
            if 'warn' in sev.lower(): nWarn += 1
            if 'error' in sev.lower() or 'warn' in sev.lower():
                p("[" + sev + "] " + txt + " | src=" + src + " | line=" + str(line))
        except Exception as me:
            p("msg dump err: " + repr(me))
    p("SUMMARY: errors=" + str(nErr) + " warnings=" + str(nWarn))
    p("BUILD_DONE")
except Exception as e:
    p("BUILD_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
