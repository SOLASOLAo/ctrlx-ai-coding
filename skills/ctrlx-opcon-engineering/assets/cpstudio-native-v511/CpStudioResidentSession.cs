using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;
using System.Xml;

// A separate epoch for every loaded project. Stale owners never follow a project switch.
public sealed class CpStudioResidentSession {
  public const string Version="5.11.0.169";
  readonly string processDirectory,executable;
  public string DirectoryPath { get; private set; }
  public string InstanceId { get; private set; }
  public string Project { get; private set; }
  public string PleExecutable { get; private set; }
  public CpStudioResidentSession() {
    var process=Process.GetCurrentProcess();
    executable=process.MainModule.FileName;
    string install=Path.GetDirectoryName(executable);
    var applications=new XmlDocument();
    applications.Load(Path.Combine(install,"config\\applications.xml"));
    var platform=applications.SelectSingleNode("/root/platforms/platform[@id='CpStudio']");
    if(platform==null||platform.Attributes["version"].Value!=Version)
      throw new InvalidOperationException("The resident adapter requires CpStudio "+Version);
    string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CpStudioNativeBridge",Version,"sessions");
    processDirectory=Path.Combine(root,process.Id+"-"+process.StartTime.ToUniversalTime().Ticks);
    Directory.CreateDirectory(processDirectory);
    string settingsFile=Path.Combine(install,"CpStudioResidentBridge.settings.json");
    var settings=Read(settingsFile);
    PleExecutable=(string)settings["pleExecutable"];
  }
  public void Activate(string project) {
    Project=Path.GetFullPath(project);
    InstanceId=Guid.NewGuid().ToString();
    DirectoryPath=Path.Combine(processDirectory,InstanceId);
    Directory.CreateDirectory(DirectoryPath);
    Write(Path.Combine(DirectoryPath,"session.json"),new Dictionary<string,object>{
      {"schemaVersion",2},{"mode","resident"},{"project",Project},{"instanceId",InstanceId},
      {"hostExecutable",executable},{"version",Version},{"pleExecutable",PleExecutable}});
  }
  public void Invalidate(string reason) {
    if(DirectoryPath==null) return;
    Write(Path.Combine(DirectoryPath,"ready.json"),new Dictionary<string,object>{
      {"complete",false},{"mode","resident"},{"project",Project},{"instanceId",InstanceId},
      {"reason",reason},{"invalidatedUtc",DateTime.UtcNow.ToString("o")}});
    DirectoryPath=null;
  }
  public void Authorize(Dictionary<string,object> request) {
    ValidateOwner(Read(Path.Combine(DirectoryPath,"owner.json")),request,Project,InstanceId);
  }
  public static void ReportError(Exception error) {
    Trace.WriteLine("CpStudio resident bridge stopped: "+error);
    try {
      string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CpStudioNativeBridge",Version);
      Directory.CreateDirectory(root);
      Write(Path.Combine(root,"error-"+Process.GetCurrentProcess().Id+".json"),new Dictionary<string,object>{
        {"error",error.ToString()},{"utc",DateTime.UtcNow.ToString("o")}});
    } catch { /* Never turn a bridge I/O failure into an engineering-desktop failure. */ }
  }
  public static void ValidateOwner(Dictionary<string,object> owner,Dictionary<string,object> request,string project,string instance) {
    object token,requestToken,ownerInstance,requestInstance,ownerProject;
    if(!owner.TryGetValue("ownerToken",out token)||!request.TryGetValue("ownerToken",out requestToken)||
       String.IsNullOrEmpty(token as string)||!String.Equals(token as string,requestToken as string,StringComparison.Ordinal)||
       !owner.TryGetValue("instanceId",out ownerInstance)||!request.TryGetValue("instanceId",out requestInstance)||
       !String.Equals(ownerInstance as string,instance,StringComparison.Ordinal)||
       !String.Equals(requestInstance as string,instance,StringComparison.Ordinal)||
       !owner.TryGetValue("project",out ownerProject)||
       !String.Equals(ownerProject as string,project,StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("Resident bridge owner, project or instance mismatch; reconnect explicitly");
  }
  static Dictionary<string,object> Read(string file) {
    return new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(file));
  }
  static void Write(string file,object value) {
    string temporary=file+"."+Guid.NewGuid().ToString()+".tmp";
    File.WriteAllText(temporary,new JavaScriptSerializer().Serialize(value));
    if(File.Exists(file)) File.Replace(temporary,file,null); else File.Move(temporary,file);
  }
}

public sealed class CpStudioResidentBridge : CpStudioNativeBridge {
  public CpStudioResidentBridge() : base("6636F385-817C-4E40-B983-2A295F95CF3E") { }
  protected override bool ResidentMode { get { return true; } }
}
