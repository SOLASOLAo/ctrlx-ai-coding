using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;

// No desktop, project, PLE, REST or UI operations: observe published messages only.
public sealed class CpStudioNativeDiagnostics {
  const int Capacity=512;
  readonly object sync=new object();
  readonly Queue<Dictionary<string,object>> entries=new Queue<Dictionary<string,object>>();
  string operationId,command;
  long sequence,dropped;
  public string CaptureStartedUtc { get; private set; }
  public void Attach(Type messageHandler) {
    var messages=messageHandler.GetEvent("Changed",BindingFlags.Public|BindingFlags.Static);
    var output=messageHandler.GetEvent("OutputChanged",BindingFlags.Public|BindingFlags.Static);
    var messageCallback=Delegate.CreateDelegate(messages.EventHandlerType,this,GetType().GetMethod("CaptureMessages"));
    var outputCallback=Delegate.CreateDelegate(output.EventHandlerType,this,GetType().GetMethod("CaptureOutput"));
    CaptureStartedUtc=DateTime.UtcNow.ToString("o");
    messages.AddEventHandler(null,messageCallback);
    try { output.AddEventHandler(null,outputCallback); }
    catch { messages.RemoveEventHandler(null,messageCallback); throw; }
  }
  public void BeginOperation(string id,string name) { lock(sync) { operationId=id; command=name; } }
  public void ResetHistory() {
    lock(sync) { entries.Clear(); sequence=0; dropped=0; operationId=null; command=null; CaptureStartedUtc=DateTime.UtcNow.ToString("o"); }
  }
  public void EndOperation() { lock(sync) { operationId=null; command=null; } }
  static object Read(object target,string name) { return target.GetType().GetProperty(name).GetValue(target,null); }
  public void CaptureMessages(object sender,EventArgs args) { Capture("messages",args); }
  public void CaptureOutput(object sender,EventArgs args) { Capture("output",args); }
  void Capture(string channel,EventArgs args) {
    string id,name;
    lock(sync) { id=operationId; name=command; }
    try {
      foreach(var message in (IEnumerable)Read(args,"Repository")) {
        try {
          Add(new Dictionary<string,object>{{"channel",channel},{"operationId",id},{"command",name},
            {"category",Read(message,"Category")},{"level",Read(message,"Level")},
            {"text",Read(message,"Text")},{"source",Read(message,"Source")},{"application",Read(message,"Application")}});
        } catch(Exception ex) { CaptureError(channel,id,name,ex); }
      }
    } catch(Exception ex) { CaptureError(channel,id,name,ex); }
  }
  void CaptureError(string channel,string id,string name,Exception ex) {
    Add(new Dictionary<string,object>{{"channel","captureError"},{"observedChannel",channel},
      {"operationId",id},{"command",name},{"error",ex.ToString()}});
  }
  void Add(Dictionary<string,object> entry) {
    lock(sync) {
      entry["sequence"]=++sequence;
      entry["publishedUtc"]=DateTime.UtcNow.ToString("o");
      if(entries.Count==Capacity) { entries.Dequeue(); dropped++; }
      entries.Enqueue(entry);
    }
  }
  public Dictionary<string,object> Snapshot(string id) {
    lock(sync) {
      var messages=new List<Dictionary<string,object>>();
      foreach(var entry in entries)
        if(id==null||String.Equals((string)entry["operationId"],id,StringComparison.Ordinal))
          messages.Add(new Dictionary<string,object>(entry));
      return new Dictionary<string,object>{{"captureStartedUtc",CaptureStartedUtc},{"snapshotUtc",DateTime.UtcNow.ToString("o")},
        {"scope",id==null?"publishedSinceBridgeReady":"publishedDuringOperation"},{"operationId",id},
        {"capacity",Capacity},{"droppedEntriesTotal",dropped},{"messages",messages},
        {"historicalMessageReplay",false},{"pleContacted",false}};
    }
  }
}
