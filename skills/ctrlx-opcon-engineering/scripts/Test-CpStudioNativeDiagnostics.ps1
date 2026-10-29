[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\assets\cpstudio-native-v511\CpStudioNativeDiagnostics.cs'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cpstudio-diagnostics-check-'+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $testRoot|Out-Null
$testFile=Join-Path $testRoot 'Check.cs'
@'
using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public sealed class Published : EventArgs {
  public IList<FakeMessage> Repository { get; set; }
}
public sealed class BrokenPublication : EventArgs {
  public object Repository { get { throw new InvalidOperationException("capture-failure"); } }
}
public class FakeMessage {
  public string Category { get { return "Engineering"; } }
  public int Level { get { return 3; } }
  public virtual string Text { get; set; }
  public string Source { get { return "/Station"; } }
  public string Application { get { return "ctrlXCore/PLC"; } }
  public static int Navigations;
  public void NavigateToSource() { Navigations++; throw new Exception("Must not navigate"); }
}
public sealed class BrokenMessage : FakeMessage {
  public override string Text { get { throw new InvalidOperationException("bad-text"); } set {} }
}
public static class FakeHandler {
  public static event EventHandler<Published> Changed;
  public static event EventHandler<Published> OutputChanged;
  public static void Publish(bool output,params FakeMessage[] messages) {
    var args=new Published { Repository=messages };
    if(output) OutputChanged(null,args); else Changed(null,args);
  }
}
public static class Check {
  static int checks;
  static void Require(bool value,string message) { if(!value) throw new Exception(message); checks++; }
  static List<Dictionary<string,object>> Entries(Dictionary<string,object> snapshot) {
    return (List<Dictionary<string,object>>)snapshot["messages"];
  }
  public static int Main() {
    var diagnostics=new CpStudioNativeDiagnostics();
    diagnostics.Attach(typeof(FakeHandler));
    string error="Error creating folder /Station! StatusCode: BadRequest Response: Request cannot be executed. A blocking operation is in progress.\r\nChinese: 阻塞操作";
    diagnostics.BeginOperation("export-A","export");
    FakeHandler.Publish(true,new FakeMessage { Text=error });
    FakeHandler.Publish(false,new BrokenMessage(),new FakeMessage { Text="Message after broken getter" });
    diagnostics.EndOperation();
    FakeHandler.Publish(true,new FakeMessage { Text="Late publication" });
    diagnostics.BeginOperation("export-B","export");
    FakeHandler.Publish(false,new FakeMessage { Text="Other attempt" });
    diagnostics.EndOperation();
    var attempt=diagnostics.Snapshot("export-A");
    var entries=Entries(attempt);
    Require(entries.Count==3,"Failed message getter must not stop later messages");
    Require((string)entries[0]["text"]==error,"Preserve complete REST failure, CRLF and Unicode");
    Require((string)entries[0]["operationId"]=="export-A"&&(string)entries[0]["command"]=="export","Operation correlation");
    Require((string)entries[0]["channel"]=="output"&&(int)entries[0]["level"]==3,"Preserve native channel and numeric level");
    Require((string)entries[0]["source"]=="/Station"&&(string)entries[0]["application"]=="ctrlXCore/PLC","Preserve native location");
    Require((string)entries[1]["channel"]=="captureError"&&((string)entries[1]["error"]).Contains("bad-text"),"Capture failures are distinct diagnostics");
    Require(Entries(diagnostics.Snapshot("export-B")).Count==1,"Do not attribute an earlier error to a later export");
    var history=Entries(diagnostics.Snapshot(null));
    Require(history.Count==5&&history[3]["operationId"]==null,"Late messages remain unscoped in history");
    Require((string)history[0]["publishedUtc"]!=null&&diagnostics.CaptureStartedUtc!=null,"Capture timestamps");
    entries[0]["text"]="Caller changed snapshot";
    Require((string)Entries(diagnostics.Snapshot("export-A"))[0]["text"]==error,"Snapshots cannot alter the buffer");
    Require(Entries(diagnostics.Snapshot(null)).Count==5&&FakeMessage.Navigations==0,"Read-only snapshots never clear or navigate");
    var json=new JavaScriptSerializer { MaxJsonLength=Int32.MaxValue }.Serialize(diagnostics.Snapshot("export-A"));
    Require(json.Contains("blocking operation")&&json.Contains("export-A"),"Detailed failure survives JSON receipt serialization");
    var bounded=new CpStudioNativeDiagnostics();
    bounded.BeginOperation("large-export","export");
    for(int i=0;i<515;i++) bounded.CaptureOutput(null,new Published { Repository=new[]{new FakeMessage { Text=i.ToString() }} });
    var limited=bounded.Snapshot(null);
    Require(Entries(limited).Count==512&&(long)limited["droppedEntriesTotal"]==3,"Bounded capture reports discarded entries");
    Require((string)Entries(limited)[0]["text"]=="3"&&(string)Entries(limited)[511]["text"]=="514","Retain latest messages in order");
    bounded.CaptureOutput(null,new BrokenPublication());
    var broken=Entries(bounded.Snapshot("large-export"));
    Require((string)broken[511]["channel"]=="captureError"&&((string)broken[511]["error"]).Contains("capture-failure"),"Bad publication must not escape into native publisher");
    bounded.ResetHistory();
    var reset=bounded.Snapshot(null);
    Require(Entries(reset).Count==0&&(long)reset["droppedEntriesTotal"]==0,"A project switch resets retained history and drop counts");
    Require(bounded.CaptureStartedUtc!=null&&reset["operationId"]==null,"New project capture starts without an old operation");
    Console.WriteLine("CpStudio diagnostics offline checks passed: "+checks);
    return 0;
  }
}
'@|Set-Content -LiteralPath $testFile -Encoding UTF8
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
$testExe=Join-Path $testRoot 'Check.exe'
& $compiler /nologo /target:exe "/out:$testExe" /reference:System.Web.Extensions.dll $source $testFile
if($LASTEXITCODE -ne 0) { throw 'Diagnostics check compilation failed' }
& $testExe
if($LASTEXITCODE -ne 0) { throw 'Diagnostics offline check failed' }

# A legacy-host capability failure must happen before a PID lookup or request write.
@{project='C:\offline-check\Station.cpsp'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $testRoot 'session.json') -Encoding UTF8
@{complete=$true;project='C:\offline-check\Station.cpsp';pid=-1}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $testRoot 'ready.json') -Encoding UTF8
$refused=$false
try {
  & (Join-Path $PSScriptRoot '..\assets\cpstudio-native-v511\Invoke-CpStudioNative.ps1') -SessionDirectory $testRoot -Command diagnostics
} catch {
  if($_.Exception.Message -notlike '*does not support diagnostics*') { throw }
  $refused=$true
}
if(-not $refused) { throw 'Legacy host was not rejected' }
foreach($file in @('client-claim.json','request.json')) {
  if(Test-Path -LiteralPath (Join-Path $testRoot $file)) { throw "Legacy refusal wrote $file" }
}
'Legacy-host refusal passed; no process lookup, claim or request'
