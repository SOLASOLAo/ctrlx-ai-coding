import sys, scriptengine as se, System
def p(s):
    sys.stdout.write(str(s) + "\n")
try:
    syst = se.system
    for name in ["commands","messages","get_messages","command","services","application_name","get_service"]:
        try: p("se.system." + name + " exists: " + str(hasattr(syst, name)))
        except Exception as e: p("probe err: " + repr(e))
    try:
        cmds = se.system.commands
        p("commands type: " + str(type(cmds)))
        try: p("commands: " + str(cmds))
        except: pass
    except Exception as e: p("commands err: " + repr(e))
    p("PROBE_OK")
except Exception as e:
    p("PROBE_ERROR: " + repr(e))
finally:
    try: sys.stdout.flush()
    except: pass
System.Environment.Exit(0)
