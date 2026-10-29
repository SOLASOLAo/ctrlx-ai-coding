using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

public static class NativeBridgeTrace {
  static readonly object gate=new object();
  static int exceptions;
  public static void Write(string value) {
    string file=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_TRACE");
    if(String.IsNullOrEmpty(file)) return;
    lock(gate) File.AppendAllText(file,DateTime.UtcNow.ToString("o")+" thread="+Thread.CurrentThread.ManagedThreadId+" "+value+Environment.NewLine);
  }
  public static void Install() {
    AppDomain.CurrentDomain.AssemblyLoad+=(sender,e)=>Write("loaded "+e.LoadedAssembly.FullName+" "+e.LoadedAssembly.Location);
    AppDomain.CurrentDomain.FirstChanceException+=(sender,e)=> { if(Interlocked.Increment(ref exceptions)<=80) Write("firstChance "+e.Exception); };
    AppDomain.CurrentDomain.UnhandledException+=(sender,e)=>Write("unhandled "+e.ExceptionObject);
    Application.ThreadException+=(sender,e)=>Write("threadException "+e.Exception);
  }
}

public sealed class NativeBridgeDomain : MarshalByRefObject {
  public void Run(string install,string extensionFolder,string[] args) {
    NativeBridgeTrace.Install();
    var entry=Assembly.GetEntryAssembly();
    NativeBridgeTrace.Write("Run base="+AppDomain.CurrentDomain.BaseDirectory+" cwd="+Environment.CurrentDirectory+" entry="+(entry==null?"null":entry.FullName)+" args="+String.Join(" | ",Environment.GetCommandLineArgs()));
    AppDomain.CurrentDomain.AssemblyResolve+=(sender,e)=> {
      NativeBridgeTrace.Write("resolve "+e.Name);
      if(new AssemblyName(e.Name).Name=="CpStudioNativeBridge") return Assembly.LoadFrom(Path.Combine(extensionFolder,"CpStudioNativeBridge.dll"));
      return null;
    };
    NativeBridgeTrace.Write("execute assembly "+Path.Combine(install,"DDP.EngineeringDesktop.exe"));
    AppDomain.CurrentDomain.ExecuteAssembly(Path.Combine(install,"DDP.EngineeringDesktop.exe"),args);
    NativeBridgeTrace.Write("entry returned");
  }
  public override object InitializeLifetimeService() { return null; }
}
public static class CpStudioNativeHost {
  [STAThread] public static void Main(string[] args) {
    NativeBridgeTrace.Install();
    NativeBridgeTrace.Write("Main");
    try {
    string install=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_INSTALL");
    if(String.IsNullOrEmpty(install)) throw new InvalidOperationException("Native install path is required");
    var setup=new AppDomainSetup {ApplicationBase=install,PrivateBinPath="OpCon",ConfigurationFile=Path.Combine(install,"DDP.EngineeringDesktop.exe.config")};
    var domain=AppDomain.CreateDomain("CpStudioNativeBridge",null,setup);
    var host=(NativeBridgeDomain)domain.CreateInstanceFromAndUnwrap(Assembly.GetExecutingAssembly().Location,typeof(NativeBridgeDomain).FullName);
    host.Run(install,Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),args);
    } catch(Exception ex) { NativeBridgeTrace.Write("main failed "+ex); }
  }
}
