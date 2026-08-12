import sys, os, time
IPC = r"C:\A_Documents\A_Projects\A_Software\PLC_Generate\TestOes\mcp_test\watcher_probe"
try:
    import clr
    from System.Threading import Thread, ThreadStart
    def work():
        try:
            time.sleep(2)
            f = open(os.path.join(IPC, "thread_alive.txt"), "w")
            f.write("alive at %f" % time.time()); f.close()
            time.sleep(4)
            f = open(os.path.join(IPC, "thread_alive2.txt"), "w")
            f.write("still alive at %f" % time.time()); f.close()
        except Exception, e:
            f = open(os.path.join(IPC, "thread_error.txt"), "w")
            f.write(repr(e)); f.close()
    t = Thread(ThreadStart(work))
    t.Start()
    f = open(os.path.join(IPC, "script_returned.txt"), "w")
    f.write("script returned at %f" % time.time()); f.close()
except Exception, e:
    f = open(os.path.join(IPC, "script_error.txt"), "w")
    f.write(repr(e)); f.close()
