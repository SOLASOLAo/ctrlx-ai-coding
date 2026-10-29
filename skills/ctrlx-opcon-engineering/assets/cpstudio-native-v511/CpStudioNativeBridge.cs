using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Rexroth.DDP.ApplicationBaseClasses;

public class CpStudioNativeBridge : ApplicationBase {
  System.Windows.Forms.Timer timer;
  int attempts;
  bool busy;
  bool exitAfterReceipt;
  object activeProject, activeEngineering;
  CpStudioNativeModel model;
  readonly CpStudioNativeDiagnostics diagnostics=new CpStudioNativeDiagnostics();
  Dictionary<string,object> lastExport;
  bool? nativeExportSuccessful;
  readonly List<Dictionary<string,object>> exportMessages=new List<Dictionary<string,object>>();
  protected virtual bool ResidentMode { get { return false; } }
  bool disabled,diagnosticsAttached;
  string sessionDirectory,expectedProject,readyPath;
  CpStudioResidentSession residentSession;
  public CpStudioNativeBridge() : this("5D409CED-1C88-4CC4-949E-F7BAA73E5281") { }
  protected CpStudioNativeBridge(string id) : base(id) { }
  protected override void DoCreate(Rexroth.DDP.DesktopServices.DesktopApplication.IDesktopApplicationCreateInfo info) {
    base.DoCreate(info);
    // A legacy isolated host explicitly owns its own bridge; never add another owner.
    disabled=ResidentMode&&!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_SESSION"));
    if(disabled) return;
    if(ResidentMode) {
      try { residentSession=new CpStudioResidentSession(); }
      catch(Exception ex) { disabled=true; CpStudioResidentSession.ReportError(ex); }
    } else {
      sessionDirectory=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_SESSION");
      expectedProject=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_PROJECT");
      readyPath=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_READY");
      Write(new Dictionary<string,object>{{"complete",false},{"extensionLoaded",true},{"stage","DoCreate"}});
    }
  }
  protected override void DoDesktopStarted() {
    base.DoDesktopStarted();
    if(disabled) return;
    timer=new System.Windows.Forms.Timer { Interval=1000 };
    if(ResidentMode) {
      timer.Tick+=ResidentTick;
      Application.ApplicationExit+=(sender,e)=> { try { residentSession.Invalidate("processExited"); } catch(Exception ex) { CpStudioResidentSession.ReportError(ex); } };
    } else timer.Tick+=Probe;
    timer.Start();
  }
  static object CurrentProject() {
    var type=Assembly.Load("OpCon.Engineering.Foundation").GetType("Bosch.OpCon.Engineering.Foundation.ProjectManager",true);
    return Property(type.GetMethod("GetInstance").Invoke(null,new object[0]),"CurrentProject");
  }
  void ResidentTick(object sender,EventArgs e) {
    if(busy) return;
    try {
      object project=CurrentProject();
      string path=project==null?null:(string)Property(project,"ProjectFile");
      if(String.IsNullOrEmpty(path)) project=null;
      if(!Object.ReferenceEquals(project,activeProject)||!String.Equals(path,expectedProject,StringComparison.OrdinalIgnoreCase)) {
        // Reject a queued old-project request through the normal receipt path first.
        if(activeProject!=null&&File.Exists(Path.Combine(sessionDirectory,"request.json"))) Command(sender,e);
        residentSession.Invalidate("projectChanged");
        activeProject=null; activeEngineering=null; expectedProject=null; model=null;
        if(project==null) return;
        object engineering=FindEngineering(project);
        if(engineering==null) return;
        residentSession.Activate(path);
        sessionDirectory=residentSession.DirectoryPath;
        expectedProject=path; readyPath=Path.Combine(sessionDirectory,"ready.json");
        activeProject=project; activeEngineering=engineering; lastExport=null;
        if(!diagnosticsAttached) {
          diagnostics.Attach(Assembly.Load("OpCon.Engineering.Foundation").GetType("Bosch.OpCon.Engineering.Foundation.MessageHandler",true));
          diagnosticsAttached=true;
        }
        diagnostics.ResetHistory();
        Write(new Dictionary<string,object>{{"complete",true},{"mode","resident"},{"project",path},
          {"instanceId",residentSession.InstanceId},{"sessionDirectory",sessionDirectory},
          {"pid",System.Diagnostics.Process.GetCurrentProcess().Id},
          {"processStartedUtc",System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o")},
          {"commands",new string[]{"status","diagnostics","inspectModel","planModelAdditions","applyModelAdditions","reloadDefinitions","planVersions","applyVersions","save","parse","export"}},
          {"guiInputUsed",false},{"mutationsPerformed",false}});
      }
      if(activeProject!=null) Command(sender,e);
    } catch(Exception ex) {
      timer.Stop();
      try { residentSession.Invalidate("bridgeError: "+ex.Message); } catch { }
      CpStudioResidentSession.ReportError(ex);
    }
  }
  static object Property(object o,string name) { return o.GetType().GetProperty(name).GetValue(o,null); }
  static object FindEngineering(object item) {
    if(item.GetType().FullName=="Bosch.OpCon.Engineering.ControlSystems.EngineeringApplication") return item;
    var core=item.GetType().GetProperty("CoreApplication");
    if(core!=null) {
      var app=core.GetValue(item,null);
      if(app!=null&&app.GetType().FullName=="Bosch.OpCon.Engineering.ControlSystems.EngineeringApplication") return app;
    }
    var property=item.GetType().GetProperty("Items");
    if(property!=null) foreach(var child in (IEnumerable)property.GetValue(item,null)) {
      var found=FindEngineering(child); if(found!=null) return found;
    }
    return null;
  }
  void Probe(object sender,EventArgs e) {
    if(++attempts>120) { timer.Stop(); Write(new Dictionary<string,object>{{"complete",false},{"error","No matching loaded isolated project after 120 seconds"}}); return; }
    try {
      var assembly=Assembly.Load("OpCon.Engineering.Foundation");
      var type=assembly.GetType("Bosch.OpCon.Engineering.Foundation.ProjectManager",true);
      var manager=type.GetMethod("GetInstance").Invoke(null,new object[0]);
      var project=Property(manager,"CurrentProject");
      if(project==null) return;
      string actual=(string)Property(project,"ProjectFile");
      string expected=Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_PROJECT");
      if(!String.Equals(Path.GetFullPath(actual),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase)) return;
      var engineering=FindEngineering(project);
      if(engineering==null) return;
      var methods=new List<string>();
      if(engineering!=null) foreach(var method in engineering.GetType().GetMethods(BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Instance))
        if(method.Name=="Export"||method.Name=="ReloadObjects"||method.Name=="menuItemParse_Click") methods.Add(method.ToString());
      var properties=new List<string>();
      foreach(var prop in engineering.GetType().GetProperties(BindingFlags.Public|BindingFlags.Instance)) properties.Add(prop.ToString());
      timer.Stop();
      activeProject=project;
      activeEngineering=engineering;
      diagnostics.Attach(assembly.GetType("Bosch.OpCon.Engineering.Foundation.MessageHandler",true));
      Write(new Dictionary<string,object>{{"complete",true},{"project",actual},{"dirty",Property(project,"IsDirty")},
        {"engineeringType",engineering==null?null:engineering.GetType().FullName},{"nativeMethods",methods},
        {"publicProperties",properties},{"pid",System.Diagnostics.Process.GetCurrentProcess().Id},
        {"processStartedUtc",System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o")},
        {"commands",new string[]{"status","diagnostics","inspectModel","planModelAdditions","applyModelAdditions","reloadDefinitions","planVersions","applyVersions","save","parse","export","shutdown"}},
        {"diagnosticsCaptureStartedUtc",diagnostics.CaptureStartedUtc},
        {"guiInputUsed",false},{"mutationsPerformed",false}});
      if(!String.IsNullOrEmpty(sessionDirectory)) { timer.Tick-=Probe; timer.Tick+=Command; timer.Interval=250; timer.Start(); }
    } catch(Exception ex) { timer.Stop(); Write(new Dictionary<string,object>{{"complete",false},{"error",ex.ToString()}}); }
  }
  const BindingFlags Members=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
  static object Invoke(object target,string method,params object[] args) { return target.GetType().GetMethod(method,Members).Invoke(target,args); }
  static object Field(object target,string field) { return target.GetType().GetField(field,Members).GetValue(target); }
  static Dictionary<string,string> Versions(object logic) {
    var result=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    foreach(DictionaryEntry entry in (IDictionary)Invoke(logic,"GetAllObjectVersionsInUse")) result.Add((string)entry.Key,entry.Value.ToString());
    return result;
  }
  static List<object> Nodes(TreeNodeCollection nodes) {
    var result=new List<object>();
    foreach(TreeNode node in nodes) { result.Add(node); result.AddRange(Nodes(node.Nodes)); }
    return result;
  }
  Dictionary<string,object> Status() {
    object logic=Property(activeEngineering,"Logic");
    return new Dictionary<string,object>{{"project",Property(activeProject,"ProjectFile")},{"dirty",Property(activeProject,"IsDirty")},{"engineeringDirty",Property(activeEngineering,"IsDirty")},
      {"versions",Versions(logic)},{"reloadActive",Property(logic,"ReloadActive")},{"guiInputUsed",false}};
  }
  void RequireCurrentProject() {
    var manager=Assembly.Load("OpCon.Engineering.Foundation").GetType("Bosch.OpCon.Engineering.Foundation.ProjectManager",true).GetMethod("GetInstance").Invoke(null,new object[0]);
    if(!Object.ReferenceEquals(Property(manager,"CurrentProject"),activeProject)) throw new InvalidOperationException("The active CpStudio project changed after bridge startup");
  }
  object VersionOperation(object logic,Dictionary<string,object> requested,bool apply) {
    if(requested==null||requested.Count==0) throw new ArgumentException("Explicit versions required");
    requested=new Dictionary<string,object>(requested,StringComparer.OrdinalIgnoreCase);
    var before=Versions(logic);
    var dialogType=activeEngineering.GetType().Assembly.GetType("Bosch.OpCon.Engineering.ControlSystems.VersionManagementDialog",true);
    using(var dialog=(Form)Activator.CreateInstance(dialogType,Members,null,new object[]{logic},null)) {
      Invoke(dialog,"OnLoad",EventArgs.Empty);
      var tree=(TreeView)Field(dialog,"treeView");
      var changes=(IDictionary)Field(dialog,"_userVersionChanges");
      foreach(var desired in requested) {
        object selectedVersion=null;
        foreach(object node in Nodes(tree.Nodes)) {
          if(!String.Equals((string)Field(node,"TypeId"),desired.Key,StringComparison.OrdinalIgnoreCase)) continue;
          foreach(object version in (IEnumerable)Field(node,"AvailableVersions"))
            if(version.ToString()==(string)desired.Value) selectedVersion=version;
        }
        if(selectedVersion==null) throw new InvalidOperationException("Exact compatible version unavailable: "+desired.Key+" "+desired.Value);
        string nativeId=null;
        foreach(var id in before.Keys) if(String.Equals(id,desired.Key,StringComparison.OrdinalIgnoreCase)) nativeId=id;
        if(nativeId==null) throw new InvalidOperationException("Requested OOD is not in current project: "+desired.Key);
        changes[nativeId]=selectedVersion;
        object definition=Invoke(logic,"GetObjectOrPeripheralDefinition",nativeId,selectedVersion);
        foreach(TreeNode root in tree.Nodes) Invoke(dialog,"SetNodeVersionRecursive",root,definition);
      }
      Invoke(dialog,"UpdateConflicts");
      ((IDictionary)Field(dialog,"_validationTable")).Clear();
      var check=dialogType.GetMethod("CheckNodeRecursive",Members);
      bool valid=(bool)check.Invoke(dialog,new object[]{tree.Nodes,Enum.ToObject(check.GetParameters()[1].ParameterType,0)});
      if(!valid) throw new InvalidOperationException("CpStudio dependency validation rejected version plan");
      var planned=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
      foreach(object node in Nodes(tree.Nodes)) {
        string id=(string)Field(node,"TypeId");
        object value=Property(node,"NewVersion");
        if(value==null) {
          if((bool)Field(node,"IsDependency")) continue; // The native validator accepts absent optional dependencies.
          throw new InvalidOperationException("Unresolved object version: "+id);
        }
        string version=value.ToString();
        if(planned.ContainsKey(id)&&planned[id]!=version) throw new InvalidOperationException("Conflicting version plan: "+id);
        planned[id]=version;
      }
      foreach(var id in planned.Keys)
        if(!before.ContainsKey(id)) throw new InvalidOperationException("Unrequested object dependency added by native plan: "+id);
      foreach(var old in before) {
        if(!planned.ContainsKey(old.Key)) throw new InvalidOperationException("Version omitted by native plan: "+old.Key);
        string expected=requested.ContainsKey(old.Key)?(string)requested[old.Key]:old.Value;
        if(planned[old.Key]!=expected) throw new InvalidOperationException("Unrequested version change: "+old.Key+" "+old.Value+" -> "+planned[old.Key]);
      }
      if(apply) {
        Invoke(dialog,"WriteNewVersionsToProject");
        Invoke(activeEngineering,"ReloadObjects");
        var after=Versions(logic);
        if(after.Count!=before.Count) throw new InvalidOperationException("Applied object set did not match native plan");
        foreach(var old in before) {
          string expected=requested.ContainsKey(old.Key)?(string)requested[old.Key]:old.Value;
          if(!after.ContainsKey(old.Key)||after[old.Key]!=expected) throw new InvalidOperationException("Applied version did not match plan: "+old.Key);
        }
      }
      return new Dictionary<string,object>{{"before",before},{"planned",planned},{"applied",apply},{"nativeDependencyCheck",valid},{"status",Status()}};
    }
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref uint size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern uint GetFinalPathNameByHandle(IntPtr file,StringBuilder name,uint size,uint flags);
  static string FinalFilePath(string path) {
    using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
      var value=new StringBuilder(32768);
      uint length=GetFinalPathNameByHandle(stream.SafeFileHandle.DangerousGetHandle(),value,32768,0);
      if(length==0||length>=32768) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return value.ToString();
    }
  }
  static string ProcessImage(int pid) {
    IntPtr handle=OpenProcess(0x1000,false,pid);
    if(handle==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    try {
      var image=new StringBuilder(32768); uint size=32768;
      if(!QueryFullProcessImageName(handle,0,image,ref size)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return image.ToString();
    } finally { CloseHandle(handle); }
  }
  void RequirePle(Dictionary<string,object> request,object logic) {
    string expected=Path.GetFullPath((string)request["plcProject"]);
    object editor=Invoke(logic,"GetPlcEditor");
    if(editor==null||editor.GetType().FullName!="Bosch.OpCon.Engineering.PlcEditorApi.CtrlX.CtrlXPlcEditor") throw new InvalidOperationException("Expected ctrlX PLC editor");
    if(!String.Equals(Path.GetFullPath((string)Field(editor,"_plcProjectPath")),expected,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Model PLC target mismatch");
    int pid=Convert.ToInt32(request["plePid"]);
    string image=ProcessImage(pid);
    string expectedExecutable=ResidentMode?residentSession.PleExecutable:Environment.GetEnvironmentVariable("CPSTUDIO_NATIVE_PLE_EXECUTABLE");
    if(String.IsNullOrEmpty(expectedExecutable)||!String.Equals(FinalFilePath(image),FinalFilePath(expectedExecutable),StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("PLE process identity mismatch: "+image);
    using(var client=new HttpClient { Timeout=TimeSpan.FromSeconds(5) }) {
      var meta=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(client.GetStringAsync("http://localhost:9002/plc/engineering/api/v2/projects/current?option=meta").Result);
      if(!String.Equals(Path.GetFullPath((string)meta["path"]),expected,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Current native REST PLC project mismatch");
    }
  }
  public DialogResult CaptureExportMessage(string message,MessageBoxButtons buttons,MessageBoxIcon icon) {
    lock(exportMessages) exportMessages.Add(new Dictionary<string,object>{{"text",message},{"buttons",buttons.ToString()},{"icon",icon.ToString()}});
    // FireExportMessage ignores the callback return; it is a notification, not a version decision.
    return buttons==MessageBoxButtons.OK?DialogResult.OK:DialogResult.Cancel;
  }
  List<Dictionary<string,object>> ExportNotifications() {
    lock(exportMessages) {
      var copy=new List<Dictionary<string,object>>();
      foreach(var message in exportMessages) copy.Add(new Dictionary<string,object>(message));
      return copy;
    }
  }
  object ExportNative() {
    Invoke(activeEngineering,"ClearBuildEvents");
    var arguments=new object[]{false};
    if(!(bool)activeEngineering.GetType().GetMethod("Validate",Members).Invoke(activeEngineering,arguments)) throw new InvalidOperationException("Native validation rejected export");
    var smart=Assembly.Load("OpCon.Engineering.Smart").GetType("Bosch.OpCon.Engineering.Smart.SmartApplication",true);
    var smartMembers=BindingFlags.Public|BindingFlags.NonPublic|BindingFlags.Static;
    if((bool)smart.GetMethod("HasDirtyForms",smartMembers).Invoke(null,null)) throw new InvalidOperationException("Save modified SmartForms before native export");
    Invoke(activeEngineering,"Save");
    activeEngineering.GetType().GetField("_appForCurrentExportRun",Members).SetValue(activeEngineering,null);
    var notifications=activeEngineering.GetType().GetEvent("ExportMessage",Members);
    if(Field(activeEngineering,"ExportMessage")!=null) throw new InvalidOperationException("Another native export message owner is active");
    var callback=Delegate.CreateDelegate(notifications.EventHandlerType,this,GetType().GetMethod("CaptureExportMessage"));
    notifications.AddEventHandler(activeEngineering,callback);
    Exception failure=null;
    using(var done=new ManualResetEvent(false)) {
      var worker=new Thread(()=> {
        try { Invoke(activeEngineering,"ExportThread",(object)CancellationToken.None); }
        catch(Exception ex) { failure=ex; }
        finally { done.Set(); }
      });
      worker.SetApartmentState(ApartmentState.STA);
      worker.CurrentCulture=Thread.CurrentThread.CurrentCulture;
      worker.CurrentUICulture=Thread.CurrentThread.CurrentUICulture;
      worker.Name="CpStudioNativeExport";
      try {
        worker.Start();
        // Native WinForms owners require their message loop while the vendor STA worker runs.
        while(!done.WaitOne(25)) Application.DoEvents();
      } finally { notifications.RemoveEventHandler(activeEngineering,callback); }
    }
    if(failure!=null) throw new InvalidOperationException("Native export worker failed",failure);
    nativeExportSuccessful=(bool)Field(activeEngineering,"_exportSuccessful");
    bool successful=nativeExportSuccessful.Value;
    var capturedNotifications=ExportNotifications();
    foreach(var message in capturedNotifications)
      if((string)message["buttons"]!="OK"||(string)message["icon"]=="Error"||(string)message["icon"]=="Hand"||(string)message["icon"]=="Stop") successful=false;
    if(!successful) throw new InvalidOperationException("Native export failed; see receipt diagnostics and notifications");
    return new Dictionary<string,object>{{"nativeExportSuccessful",nativeExportSuccessful},{"notifications",capturedNotifications},{"status",Status()}};
  }
  void Command(object sender,EventArgs e) {
    if(busy) return;
    string session=sessionDirectory;
    string requestFile=Path.Combine(session,"request.json");
    if(!File.Exists(requestFile)) return;
    busy=true;
    string id=Guid.NewGuid().ToString();
    string command=null;
    var response=new Dictionary<string,object>{{"complete",false},{"pid",System.Diagnostics.Process.GetCurrentProcess().Id},{"guiInputUsed",false}};
    try {
      if(new FileInfo(requestFile).Length>65536) throw new InvalidOperationException("Request too large");
      var request=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(requestFile));
      id=Guid.Parse((string)request["id"]).ToString();
      string receipt=Path.Combine(session,"response-"+id+".json");
      if(File.Exists(receipt)||File.Exists(Path.Combine(session,"running-"+id+".json"))) {
        File.Move(requestFile,Path.Combine(session,"rejected-"+Guid.NewGuid().ToString()+".json"));
        id=Guid.NewGuid().ToString();
        throw new InvalidOperationException("Operation ID already consumed; no command replayed");
      }
      File.Move(requestFile,Path.Combine(session,"running-"+id+".json"));
      response["id"]=id;
      RequireCurrentProject();
      if(ResidentMode) residentSession.Authorize(request);
      string expected=expectedProject;
      string actual=(string)Property(activeProject,"ProjectFile");
      if(!String.Equals(Path.GetFullPath(actual),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase)||
         !String.Equals(Path.GetFullPath((string)request["project"]),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("Loaded project identity mismatch");
      command=(string)request["command"];
      response["command"]=command;
      diagnostics.BeginOperation(id,command);
      if(command=="export") { nativeExportSuccessful=null; lock(exportMessages) exportMessages.Clear(); }
      object logic=Property(activeEngineering,"Logic");
      switch(command) {
        case "status": response["result"]=Status(); break;
        case "inspectModel": case "planModelAdditions": case "applyModelAdditions":
          if(model==null) model=new CpStudioNativeModel(logic);
          var modelRequest=request.ContainsKey("model")?request["model"] as Dictionary<string,object>:null;
          if(modelRequest==null) throw new ArgumentException("A typed model request is required");
          response["result"]=command=="inspectModel"?model.Inspect(modelRequest):command=="planModelAdditions"?model.Preview(modelRequest):model.Apply(modelRequest);
          break;
        case "diagnostics":
          response["result"]=new Dictionary<string,object>{{"project",actual},{"mutationsPerformed",false},{"pleContacted",false},
            {"history",diagnostics.Snapshot(null)},{"lastExport",lastExport}};
          break;
        case "reloadDefinitions": Invoke(logic,"ReloadObjectAndPeripheralDefinitions"); response["result"]=Status(); break;
        case "planVersions": case "applyVersions":
          response["result"]=VersionOperation(logic,(Dictionary<string,object>)request["versions"],command=="applyVersions"); break;
        case "save": Invoke(activeEngineering,"Save"); Invoke(activeProject,"Save"); response["result"]=Status(); break;
        case "parse":
          RequirePle(request,logic);
          Invoke(activeEngineering,"menuItemParse_Click",new object[]{null});
          response["result"]=Status(); break;
        case "export":
          RequirePle(request,logic);
          response["result"]=ExportNative();
          break;
        case "shutdown":
          if(ResidentMode) throw new InvalidOperationException("Close an interactive CpStudio through its normal saved-project lifecycle; resident clients cannot shut it down");
          if((bool)Property(activeProject,"IsDirty")||(bool)Property(activeEngineering,"IsDirty")) throw new InvalidOperationException("Save the isolated model before shutdown");
          var finalStatus=Status();
          var manager=Assembly.Load("OpCon.Engineering.Foundation").GetType("Bosch.OpCon.Engineering.Foundation.ProjectManager",true).GetMethod("GetInstance").Invoke(null,new object[0]);
          Invoke(manager,"Unload");
          if(Property(manager,"CurrentProject")!=null) throw new InvalidOperationException("Native project unload did not complete");
          finalStatus["projectUnloaded"]=true;
          response["result"]=finalStatus; exitAfterReceipt=true; break;
        default: throw new InvalidOperationException("Unknown native command");
      }
      response["complete"]=true;
    } catch(Exception ex) {
      response["error"]=ex.ToString();
      if(File.Exists(requestFile)) File.Move(requestFile,Path.Combine(session,"rejected-"+Guid.NewGuid().ToString()+".json"));
    }
    finally {
      if(command=="export") {
        response["nativeExportSuccessful"]=nativeExportSuccessful;
        response["notifications"]=ExportNotifications();
        response["diagnostics"]=diagnostics.Snapshot(id);
        lastExport=new Dictionary<string,object>{{"id",id},{"complete",response["complete"]},
          {"nativeExportSuccessful",nativeExportSuccessful},{"notifications",response["notifications"]},
          {"diagnostics",response["diagnostics"]},{"error",response.ContainsKey("error")?response["error"]:null}};
      }
      diagnostics.EndOperation();
      string receipt=Path.Combine(session,"response-"+id+".json");
      string temporary=receipt+".tmp";
      File.WriteAllText(temporary,new JavaScriptSerializer { MaxJsonLength=Int32.MaxValue }.Serialize(response));
      if(!File.Exists(receipt)) File.Move(temporary,receipt);
      busy=false;
      if(exitAfterReceipt) Application.Exit();
    }
  }
  void Write(object result) {
    string file=readyPath;
    string temporary=file+".tmp";
    File.WriteAllText(temporary,new JavaScriptSerializer().Serialize(result));
    if(File.Exists(file)) File.Replace(temporary,file,null); else File.Move(temporary,file);
  }
}
