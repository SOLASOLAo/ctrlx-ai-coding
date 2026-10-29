using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using Bosch.OpCon.Data;

// Typed, additive model operations. No method names, CLR types or values come from the caller.
public sealed class CpStudioNativeModel {
  readonly object logic;
  readonly Dictionary<string,Plan> plans=new Dictionary<string,Plan>(StringComparer.Ordinal);
  readonly JavaScriptSerializer json=new JavaScriptSerializer { MaxJsonLength=16000000 };
  const int MaxNodes=200000, MaxItems=256, MaxArrayMembers=4096;
  sealed class Item {
    public string Kind,Name,DataType,TypePath,TypeGuid;
    public int StringLength;
    public List<int[]> Bounds=new List<int[]>();
    public List<Item> Members=new List<Item>();
  }
  sealed class Addition { public BaseData Parent; public Item Item; }
  sealed class Plan {
    public string Id;
    public List<Addition> Additions=new List<Addition>();
    public Dictionary<string,string> Before,After;
    public object Preview,Result;
    public bool Started;
  }
  public CpStudioNativeModel(object engineeringLogic) { logic=engineeringLogic; }
  static object Property(object value,string name) {
    if(value==null) return null;
    var property=value.GetType().GetProperty(name);
    return property==null?null:property.GetValue(value,null);
  }
  static string PathOf(BaseData item) {
    var parts=new List<string>();
    var seen=new HashSet<BaseData>();
    for(var current=item;current!=null;) {
      if(!seen.Add(current)||parts.Count>=64) throw new InvalidOperationException("Invalid model parent chain");
      parts.Insert(0,current.Name);
      // Native array children are named ArrayName[index]; omit the duplicated array parent.
      var parent=current.Parent;
      current=parent is ArrayData&&current.Name.StartsWith(parent.Name+"[",StringComparison.Ordinal)?parent.Parent:parent;
    }
    return String.Join(".",parts.ToArray());
  }
  static bool InScope(string path) { return path=="Types"||path.StartsWith("Types.",StringComparison.Ordinal)||path=="Variables"||path.StartsWith("Variables.",StringComparison.Ordinal); }
  static void Walk(object item,HashSet<object> seen,List<BaseData> nodes) {
    if(item==null||!seen.Add(item)) return;
    var data=item as BaseData;
    if(data!=null&&InScope(PathOf(data))) {
      nodes.Add(data);
      if(nodes.Count>MaxNodes) throw new InvalidOperationException("Model inspection exceeds the bounded scope");
    }
    var children=Property(item,"Items") as IEnumerable;
    if(children!=null) foreach(object child in children) Walk(child,seen,nodes);
  }
  Dictionary<string,BaseData> Index() {
    var nodes=new List<BaseData>();
    Walk(Property(logic,"LogicHandler"),new HashSet<object>(),nodes);
    var result=new Dictionary<string,BaseData>(StringComparer.OrdinalIgnoreCase);
    foreach(var node in nodes) {
      string path=PathOf(node);
      if(result.ContainsKey(path)) throw new InvalidOperationException("Ambiguous model path: "+path);
      result.Add(path,node);
    }
    if(result.Count==0) throw new InvalidOperationException("Native Types/Variables model is unavailable");
    return result;
  }
  static void CheckReadExpansion(BaseData anchor,string suffix) {
    BaseData schema=anchor;
    foreach(string part in suffix.TrimStart('.').Split('.')) {
      var match=Regex.Match(part,@"^(?<name>[^.\[\]]+)?(?:\[(?<indices>-?\d+(?:,-?\d+)*)\])?$");
      if(!match.Success||part.Length==0) throw new ArgumentException("Use an exact native variable member/index path");
      if(match.Groups["name"].Success) {
        var instance=schema as StructInst;
        if(instance!=null) schema=instance.GetStructDataDefinition();
        if(!(schema is StructData)) throw new ArgumentException("Variable path does not reference a struct member: "+part);
        schema=Child(schema,match.Groups["name"].Value);
        if(schema==null) throw new ArgumentException("Unknown native variable member: "+part);
      }
      if(match.Groups["indices"].Success) {
        var array=schema as ArrayData;
        if(array==null) throw new ArgumentException("Indexed variable member is not an array");
        string[] indices=match.Groups["indices"].Value.Split(',');
        if(indices.Length!=array.Dimensions) throw new ArgumentException("Native array index dimension mismatch");
        int[] lower={array.MinLim_Dim1,array.MinLim_Dim2,array.MinLim_Dim3},upper={array.MaxLim_Dim1,array.MaxLim_Dim2,array.MaxLim_Dim3};
        long size=1;
        for(int i=0;i<array.Dimensions;i++) {
          int index;
          if(!Int32.TryParse(indices[i],out index)||index<lower[i]||index>upper[i]) throw new ArgumentException("Native array index is outside its explicit bounds");
          size*=1L+upper[i]-lower[i];
          if(size>MaxArrayMembers) throw new ArgumentException("Native array expansion exceeds the bounded read scope; inspect its definition");
        }
        schema=array.GetArrayDataDefinition();
      }
    }
  }
  static BaseData ResolveRead(Dictionary<string,BaseData> index,string path) {
    BaseData found;
    if(index.TryGetValue(path,out found)) {
      if(PathOf(found)!=path) throw new ArgumentException("Use the exact model path case: "+path);
      return found;
    }
    if(!path.StartsWith("Variables.",StringComparison.Ordinal)) throw new ArgumentException("Unknown model inspection path: "+path);
    BaseData anchor=null; string prefix=null;
    foreach(var pair in index) if((pair.Value is StructInst||pair.Value is ArrayData)&&
      (path.StartsWith(pair.Key+".",StringComparison.Ordinal)||path.StartsWith(pair.Key+"[",StringComparison.Ordinal))&&
      (prefix==null||pair.Key.Length>prefix.Length)) { anchor=pair.Value; prefix=pair.Key; }
    if(anchor==null) throw new ArgumentException("Unknown model inspection path: "+path);
    string suffix=path.Substring(prefix.Length);
    CheckReadExpansion(anchor,suffix);
    var resolver=Assembly.Load("OpCon.Engineering.ControlSystems.Interfaces").GetType("Bosch.OpCon.Engineering.ControlSystems.Interfaces.StructHandling",true);
    found=anchor;
    foreach(string part in suffix.TrimStart('.').Split('.')) {
      var match=Regex.Match(part,@"^(?<name>[^.\[\]]+)?(?:\[(?<indices>-?\d+(?:,-?\d+)*)\])?$");
      if(match.Groups["name"].Success) {
        string name=match.Groups["name"].Value;
        var instance=found as StructInst;
        if(instance!=null) {
          instance.ExpandMember=true;
          found=Child(instance,name);
          if(found==null&&instance.Name.IndexOf('[')<0) found=resolver.GetMethod("GetItemByFullname").Invoke(null,new object[]{instance.Name+"."+name,instance,true,false}) as BaseData;
        } else found=Child(found,name);
      }
      if(found==null) break;
      if(match.Groups["indices"].Success) {
        var array=found as ArrayData;
        if(array==null) throw new InvalidOperationException("Native variable did not resolve to the checked array");
        // Like the vendor variable selector, materialize the bounded array cache.
        array.ExpandMember=true;
        string[] parts=match.Groups["indices"].Value.Split(',');
        int first=Int32.Parse(parts[0],CultureInfo.InvariantCulture);
        found=parts.Length==1?array.GetArrayMember(first):parts.Length==2?array.GetArrayMember(first,Int32.Parse(parts[1],CultureInfo.InvariantCulture)):array.GetArrayMember(first,Int32.Parse(parts[1],CultureInfo.InvariantCulture),Int32.Parse(parts[2],CultureInfo.InvariantCulture));
        // The legacy member-name regex omits negative indexes; the native collection still has them.
        if(found==null) found=Child(array,array.Name+"["+String.Join(",",parts)+"]");
      }
      if(found==null) break;
    }
    if(found==null||PathOf(found)!=path) throw new InvalidOperationException("Native variable resolution did not match "+path+"; actual: "+(found==null?"<none>":PathOf(found)));
    return found;
  }
  static Dictionary<string,object> Object(object value) {
    var result=value as Dictionary<string,object>;
    if(result==null) throw new ArgumentException("Expected a JSON object");
    return result;
  }
  static void Keys(Dictionary<string,object> value,params string[] allowed) {
    var names=new HashSet<string>(allowed,StringComparer.Ordinal);
    foreach(string key in value.Keys) if(!names.Contains(key)) throw new ArgumentException("Unsupported model field: "+key);
  }
  static string Text(Dictionary<string,object> value,string key,bool required) {
    object raw;
    if(!value.TryGetValue(key,out raw)) { if(required) throw new ArgumentException("Missing model field: "+key); return null; }
    var result=raw as string;
    if(String.IsNullOrWhiteSpace(result)||result.Length>1024) throw new ArgumentException("Invalid model text: "+key);
    return result;
  }
  static int Integer(Dictionary<string,object> value,string key) {
    object raw;
    if(!value.TryGetValue(key,out raw)||!(raw is int)) throw new ArgumentException("An explicit Int32 is required: "+key);
    return (int)raw;
  }
  static IList List(object value) {
    var result=value as IList;
    if(result==null) throw new ArgumentException("Expected a JSON array");
    return result;
  }
  static string Primitive(string value) {
    if(value==null||!Regex.IsMatch(value,"^(BOOL|SINT|BYTE|INT|WORD|DINT|DWORD|REAL|LREAL|STRING|TIME|DT)$")) throw new ArgumentException("Unsupported native basic type: "+value);
    return value;
  }
  static Item ParseItem(Dictionary<string,object> raw,ref int count,bool member) {
    if(++count>MaxItems) throw new ArgumentException("Too many model additions");
    Keys(raw,"kind","name","dataType","stringLength","typePath","typeGuid","bounds","members");
    var item=new Item { Kind=Text(raw,"kind",true),Name=Text(raw,"name",true),DataType=Text(raw,"dataType",false),TypePath=Text(raw,"typePath",false),TypeGuid=Text(raw,"typeGuid",false) };
    if(!Regex.IsMatch(item.Name,"^[A-Za-z_][A-Za-z0-9_]{0,79}$")) throw new ArgumentException("Use an unambiguous IEC identifier: "+item.Name);
    if(item.Kind!="struct"&&item.Kind!="variable"&&item.Kind!="structInstance"&&item.Kind!="array") throw new ArgumentException("Unsupported additive model kind: "+item.Kind);
    if(item.Kind=="struct") {
      if(member||item.DataType!=null||item.TypePath!=null||item.TypeGuid!=null||raw.ContainsKey("bounds")||raw.ContainsKey("stringLength")) throw new ArgumentException("Struct definitions belong in a Types container");
      if(raw.ContainsKey("members")) {
        var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(object child in List(raw["members"])) {
          var parsed=ParseItem(Object(child),ref count,true);
          if(!names.Add(parsed.Name)) throw new ArgumentException("Duplicate requested member: "+parsed.Name);
          item.Members.Add(parsed);
        }
      }
      return item;
    }
    if(raw.ContainsKey("members")) throw new ArgumentException("Only a struct definition accepts members");
    if(item.Kind=="structInstance"||(item.Kind=="array"&&item.TypePath!=null)) {
      if(item.DataType!=null||item.TypePath==null||!item.TypePath.StartsWith("Types.",StringComparison.Ordinal)) throw new ArgumentException("An exact Types definition path is required");
    } else {
      Primitive(item.DataType);
      if(item.TypePath!=null||item.TypeGuid!=null) throw new ArgumentException("A basic type cannot also reference a struct");
    }
    if(item.DataType=="STRING") {
      item.StringLength=Integer(raw,"stringLength");
      if(item.StringLength<1||item.StringLength>65535) throw new ArgumentException("Invalid fixed STRING length");
    } else if(raw.ContainsKey("stringLength")) throw new ArgumentException("stringLength requires STRING");
    if(item.Kind=="array") {
      if(!raw.ContainsKey("bounds")) throw new ArgumentException("Fixed arrays require explicit bounds");
      long length=1;
      foreach(object dimension in List(raw["bounds"])) {
        var bound=Object(dimension); Keys(bound,"lower","upper");
        int lower=Integer(bound,"lower"),upper=Integer(bound,"upper");
        if(upper<lower) throw new ArgumentException("Array upper bound precedes lower bound");
        if(item.Bounds.Count>0&&upper<0) throw new ArgumentException("The native model reserves a negative upper bound for an unused second/third dimension");
        length*=1L+upper-lower;
        if(length>MaxArrayMembers||item.Bounds.Count>=3) throw new ArgumentException("Array dimensions or capacity exceed the bounded scope");
        item.Bounds.Add(new[]{lower,upper});
      }
      if(item.Bounds.Count==0) throw new ArgumentException("Fixed arrays need at least one dimension");
    } else if(raw.ContainsKey("bounds")) throw new ArgumentException("Only arrays accept bounds");
    return item;
  }
  static bool IsStructDefinition(BaseData node) { return node.GetType().FullName=="Bosch.OpCon.Data.StructData"||node.GetType().FullName=="Bosch.OpCon.Engineering.Types.ModelTreeStructData"; }
  static string Kind(BaseData node) { return IsStructDefinition(node)?"struct":node is ArrayData?"array":node is StructInst?"structInstance":BasicType(node)!=null?"variable":"container"; }
  static string BasicType(BaseData node) {
    switch(node.GetType().Name) {
      case "BooleanData": return "BOOL"; case "SByteData": return "SINT"; case "ByteData": return "BYTE";
      case "ShortData": return "INT"; case "UShortData": return "WORD"; case "IntData": return "DINT"; case "UIntData": return "DWORD";
      case "RealData": return "REAL"; case "DoubleData": return "LREAL"; case "StringData": return "STRING"; case "TimeData": return "TIME"; case "DateTimeData": return "DT";
      default: return null;
    }
  }
  static List<object> Bounds(ArrayData array) {
    var result=new List<object>();
    int[] lower={array.MinLim_Dim1,array.MinLim_Dim2,array.MinLim_Dim3},upper={array.MaxLim_Dim1,array.MaxLim_Dim2,array.MaxLim_Dim3};
    for(int i=0;i<array.Dimensions;i++) result.Add(new Dictionary<string,object>{{"lower",lower[i]},{"upper",upper[i]}});
    return result;
  }
  static Dictionary<string,object> Describe(BaseData node) {
    var record=new Dictionary<string,object>{{"path",PathOf(node)},{"guid",node.Guid.ToString()},{"modelType",node.GetType().FullName},{"kind",Kind(node)},{"name",node.Name}};
    var variable=node as VarBaseData;
    if(variable!=null&&variable.Defined!=null) { record["typePath"]=PathOf(variable.Defined); record["typeGuid"]=variable.Defined.Guid.ToString(); }
    var array=node as ArrayData;
    if(array!=null) { record["bounds"]=Bounds(array); record["dataType"]=array.Type.ToString(); if(array.Type==VarPlcTypes.STRING) record["stringLength"]=array.StringLength; }
    else if(BasicType(node)!=null) record["dataType"]=BasicType(node);
    if(variable!=null&&!(node is StructData)&&!(node is StructInst)&&!(node is ArrayData)) record["value"]=Convert.ToString(Property(node,"ValueString"),CultureInfo.InvariantCulture);
    var text=node as StringData; if(text!=null) record["stringLength"]=text.Length;
    record["childCount"]=node.Items.Count;
    return record;
  }
  Dictionary<string,string> Snapshot(Dictionary<string,BaseData> index) {
    var result=new Dictionary<string,string>(StringComparer.Ordinal);
    foreach(var pair in index) {
      var record=Describe(pair.Value); record.Remove("childCount");
      result.Add(pair.Key,json.Serialize(record));
    }
    return result;
  }
  static void Preserve(Dictionary<string,string> before,Dictionary<string,string> after,bool exact) {
    if(exact&&before.Count!=after.Count) throw new InvalidOperationException("Model changed since the preview; inspect and create a fresh plan");
    foreach(var pair in before) {
      string current;
      if(!after.TryGetValue(pair.Key,out current)||current!=pair.Value) throw new InvalidOperationException("Existing model declaration or value changed: "+pair.Key);
    }
  }
  static BaseData Target(Dictionary<string,BaseData> index,Dictionary<string,object> reference) {
    Keys(reference,"path","guid","modelType");
    string path=Text(reference,"path",true); BaseData node;
    if(!index.TryGetValue(path,out node)||PathOf(node)!=path||node.Guid.ToString()!=Text(reference,"guid",true)||node.GetType().FullName!=Text(reference,"modelType",true)) throw new InvalidOperationException("Exact model target identity mismatch: "+path);
    return node;
  }
  static void ParentAllows(BaseData parent,Item item) {
    string name=parent.GetType().FullName;
    string path=PathOf(parent);
    if(path=="Types.STD"||path.StartsWith("Types.STD.",StringComparison.Ordinal)||path=="Variables.STD"||path.StartsWith("Variables.STD.",StringComparison.Ordinal)) throw new InvalidOperationException("Supplier STD definitions and variables are read-only");
    if(item.Kind=="struct") {
      if(!(path=="Types"||path.StartsWith("Types.",StringComparison.Ordinal))||(name!="Bosch.OpCon.Engineering.Types.TypesFolderData"&&name!="Bosch.OpCon.Engineering.Types.TypesMasterData"&&name!="Bosch.OpCon.Engineering.ControlSystems.ConfigUnitReferenceData")) throw new InvalidOperationException("Struct definitions require an exact editable Types container");
    } else if(name!="Bosch.OpCon.Data.StructData"&&name!="Bosch.OpCon.Engineering.Types.ModelTreeStructData"&&name!="Bosch.OpCon.Engineering.Variables.PlcVarFolderData"&&name!="Bosch.OpCon.Engineering.Variables.PlcVarChapterData"&&name!="Bosch.OpCon.Engineering.Variables.VarMasterData") throw new InvalidOperationException("Add members through their Types definition, or choose an editable Variables container");
    if(parent.Logic==null) throw new InvalidOperationException("Model target is not attached to its native logic");
  }
  static BaseData Child(BaseData parent,string name) {
    BaseData found=null;
    foreach(BaseData child in parent.Items) if(String.Equals(child.Name,name,StringComparison.OrdinalIgnoreCase)) {
      if(found!=null||child.Name!=name) throw new InvalidOperationException("Duplicate or case-conflicting model name: "+name);
      found=child;
    }
    return found;
  }
  static void Matches(BaseData node,Item item) {
    if(Kind(node)!=item.Kind) throw new InvalidOperationException("Existing name has another model kind: "+PathOf(node));
    var variable=node as VarBaseData;
    if(item.TypePath!=null) {
      if(variable==null||variable.Defined==null||PathOf(variable.Defined)!=item.TypePath||(item.TypeGuid!=null&&variable.Defined.Guid.ToString()!=item.TypeGuid)) throw new InvalidOperationException("Existing struct reference differs: "+PathOf(node));
    } else if(item.Kind=="variable"&&BasicType(node)!=item.DataType) throw new InvalidOperationException("Existing basic type differs: "+PathOf(node));
    var array=node as ArrayData;
    if(array!=null) {
      if(array.Type.ToString()!=(item.TypePath!=null?"RefType":item.DataType)||array.Dimensions!=item.Bounds.Count) throw new InvalidOperationException("Existing array type or dimensions differ: "+PathOf(node));
      int[] lower={array.MinLim_Dim1,array.MinLim_Dim2,array.MinLim_Dim3},upper={array.MaxLim_Dim1,array.MaxLim_Dim2,array.MaxLim_Dim3};
      for(int i=0;i<item.Bounds.Count;i++) if(lower[i]!=item.Bounds[i][0]||upper[i]!=item.Bounds[i][1]) throw new InvalidOperationException("Existing array bounds differ: "+PathOf(node));
    }
    if(item.DataType=="STRING"&&(array!=null?array.StringLength:((StringData)node).Length)!=item.StringLength) throw new InvalidOperationException("Existing STRING length differs: "+PathOf(node));
  }
  static void Reference(Item item,Dictionary<string,BaseData> index,HashSet<string> newTypes) {
    if(item.TypePath!=null) {
      BaseData definition;
      if(index.TryGetValue(item.TypePath,out definition)) {
        if(!IsStructDefinition(definition)||PathOf(definition)!=item.TypePath||(definition.Guid.ToString()!=item.TypeGuid&&!(item.TypeGuid==null&&newTypes.Contains(item.TypePath)))) throw new InvalidOperationException("Exact struct definition identity mismatch: "+item.TypePath);
      } else if(!newTypes.Contains(item.TypePath)||item.TypeGuid!=null) throw new InvalidOperationException("Referenced struct is unavailable: "+item.TypePath);
    }
    foreach(var member in item.Members) Reference(member,index,newTypes);
  }
  static void PreviewItem(BaseData parent,string parentPath,Item item,List<object> actions,HashSet<string> reserved) {
    string path=parentPath+"."+item.Name;
    if(!reserved.Add(path)) throw new InvalidOperationException("Overlapping model additions: "+path);
    BaseData existing=parent==null?null:Child(parent,item.Name);
    if(existing!=null) Matches(existing,item);
    actions.Add(new Dictionary<string,object>{{"path",path},{"action",existing==null?"add":"unchanged"},{"kind",item.Kind},{"dataType",item.DataType},{"typePath",item.TypePath},{"bounds",item.Bounds},{"stringLength",item.StringLength}});
    foreach(var member in item.Members) PreviewItem(existing,path,member,actions,reserved);
  }
  static void AddEdge(Dictionary<string,List<string>> graph,string source,string target) {
    List<string> edges; if(!graph.TryGetValue(source,out edges)) graph[source]=edges=new List<string>();
    edges.Add(target);
  }
  static bool Reach(Dictionary<string,List<string>> graph,string source,string target,HashSet<string> visited) {
    if(source==target) return true;
    if(!visited.Add(source)) return false;
    List<string> edges;
    if(graph.TryGetValue(source,out edges)) foreach(string edge in edges) if(Reach(graph,edge,target,visited)) return true;
    return false;
  }
  static void Cycles(List<Addition> additions,Dictionary<string,BaseData> index) {
    var graph=new Dictionary<string,List<string>>(StringComparer.Ordinal);
    foreach(BaseData node in index.Values) {
      var variable=node as VarBaseData;
      if(variable==null||!(variable.Defined is StructData)||(!(node is StructInst)&&!(node is ArrayData))) continue;
      if(node.Parent is StructData) AddEdge(graph,PathOf(node.Parent),PathOf(variable.Defined));
    }
    foreach(var addition in additions) {
      string path=PathOf(addition.Parent);
      if(addition.Item.Kind=="struct") {
        path+="."+addition.Item.Name;
        foreach(var member in addition.Item.Members) if(member.TypePath!=null) AddEdge(graph,path,member.TypePath);
      } else if(addition.Parent is StructData&&addition.Item.TypePath!=null) AddEdge(graph,path,addition.Item.TypePath);
    }
    foreach(var entry in graph) foreach(string target in entry.Value) if(Reach(graph,target,entry.Key,new HashSet<string>(StringComparer.Ordinal))) throw new InvalidOperationException("Recursive by-value struct reference: "+entry.Key);
  }
  public object Inspect(Dictionary<string,object> request) {
    Keys(request,"paths","depth");
    int depth=request.ContainsKey("depth")?Integer(request,"depth"):1;
    if(depth<0||depth>4) throw new ArgumentException("Inspection depth must be 0..4");
    var index=Index(); int initialNodes=index.Count; var roots=new List<string>();
    if(request.ContainsKey("paths")) foreach(object path in List(request["paths"])) {
      if(!(path is string)||String.IsNullOrWhiteSpace((string)path)) throw new ArgumentException("An exact model inspection path is required");
      ResolveRead(index,(string)path); roots.Add((string)path);
    }
    else { roots.Add("Types"); roots.Add("Variables"); }
    index=Index();
    var records=new List<object>();
    foreach(var pair in index) foreach(string root in roots) {
      bool descendant=pair.Key.StartsWith(root+".",StringComparison.Ordinal)||pair.Key.StartsWith(root+"[",StringComparison.Ordinal);
      string suffix=descendant?pair.Key.Substring(root.Length).TrimStart('.'):null;
      int levels=suffix==null?Int32.MaxValue:suffix.Split('.').Length;
      if(suffix!=null) foreach(char c in suffix) if(c=='[') levels++;
      if(suffix!=null&&suffix.StartsWith("[",StringComparison.Ordinal)) levels--;
      if(pair.Key==root||(descendant&&levels<=depth)) { records.Add(Describe(pair.Value)); if(records.Count>5000) throw new InvalidOperationException("Narrow the model inspection scope"); break; }
    }
    return new Dictionary<string,object>{{"nodes",records},{"indexedNodes",index.Count},{"materializedNodes",index.Count-initialNodes},{"mutationsPerformed",false}};
  }
  public object Preview(Dictionary<string,object> request) {
    Keys(request,"additions");
    if(!request.ContainsKey("additions")) throw new ArgumentException("Explicit additions are required");
    var rawAdditions=List(request["additions"]);
    if(rawAdditions.Count==0||rawAdditions.Count>MaxItems) throw new ArgumentException("Use 1..256 model additions");
    var index=Index(); var plan=new Plan { Id=Guid.NewGuid().ToString(),Before=Snapshot(index) };
    int count=0;
    var newTypes=new HashSet<string>(StringComparer.Ordinal);
    foreach(object raw in rawAdditions) {
      var addition=Object(raw); Keys(addition,"parent","item");
      if(!addition.ContainsKey("parent")||!addition.ContainsKey("item")) throw new ArgumentException("Each addition needs parent and item");
      var parent=Target(index,Object(addition["parent"])); var item=ParseItem(Object(addition["item"]),ref count,false);
      ParentAllows(parent,item);
      plan.Additions.Add(new Addition { Parent=parent,Item=item });
      if(item.Kind=="struct") newTypes.Add(PathOf(parent)+"."+item.Name);
    }
    var actions=new List<object>(); var reserved=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach(var addition in plan.Additions) { Reference(addition.Item,index,newTypes); PreviewItem(addition.Parent,PathOf(addition.Parent),addition.Item,actions,reserved); }
    Cycles(plan.Additions,index);
    if(plans.Count>=16) throw new InvalidOperationException("Too many retained previews; use a fresh owned model session");
    plan.Preview=new Dictionary<string,object>{{"planId",plan.Id},{"actions",actions},{"protectedExistingNodes",plan.Before.Count},{"mutationsPerformed",false}};
    plans.Add(plan.Id,plan);
    return plan.Preview;
  }
  static VarBaseData Basic(Item item,BaseData parent) {
    switch(item.DataType) {
      case "BOOL": return new BooleanData(item.Name,parent); case "SINT": return new SByteData(item.Name,parent); case "BYTE": return new ByteData(item.Name,parent);
      case "INT": return new ShortData(item.Name,parent); case "WORD": return new UShortData(item.Name,parent); case "DINT": return new IntData(item.Name,parent); case "DWORD": return new UIntData(item.Name,parent);
      case "REAL": return new RealData(item.Name,parent); case "LREAL": return new DoubleData(item.Name,parent); case "TIME": return new TimeData(item.Name,parent); case "DT": return new DateTimeData(item.Name,parent);
      case "STRING": var text=new StringData(item.Name,parent); text.Length=item.StringLength; return text;
      default: throw new ArgumentException("Unsupported native basic type");
    }
  }
  static BaseData Create(BaseData parent,Item item,Dictionary<string,BaseData> index) {
    BaseData existing=Child(parent,item.Name);
    if(existing!=null) { Matches(existing,item); return existing; }
    BaseData created;
    if(item.Kind=="structInstance") created=((StructData)index[item.TypePath]).AddStructInst((VarBaseData)parent,item.Name);
    else {
      if(item.Kind=="struct") created=new StructData(item.Name,parent);
      else if(item.Kind=="variable") created=Basic(item,parent);
      else {
        var array=new ArrayData(item.Name,parent);
        array.ExpandMember=false;
        array.Type=item.TypePath!=null?VarPlcTypes.RefType:(VarPlcTypes)Enum.Parse(typeof(VarPlcTypes),item.DataType);
        if(item.TypePath!=null) { array.Defined=index[item.TypePath]; array.TypeName=index[item.TypePath].Name; array.ExportMember=true; }
        if(item.DataType=="STRING") array.StringLength=item.StringLength;
        // CpStudio uses -1, not zero, to represent an unused second/third dimension.
        int[] lower=new int[3],upper={-1,-1,-1};
        for(int i=0;i<item.Bounds.Count;i++) { lower[i]=item.Bounds[i][0]; upper[i]=item.Bounds[i][1]; }
        array.SetDimensionMemberCount(lower[0],upper[0],lower[1],upper[1],lower[2],upper[2]);
        created=array;
      }
      var permission=parent.Logic.CanInsert(parent,created);
      if(permission==null||!permission.CanInsertOnNode) throw new InvalidOperationException("Native model rejects insertion at "+PathOf(parent));
      if(!parent.Logic.AddData(created)) throw new InvalidOperationException("Native model insertion failed at "+PathOf(parent));
    }
    if(created==null||!object.ReferenceEquals(Child(parent,item.Name),created)) throw new InvalidOperationException("Native addition did not preserve the requested identity/name");
    Matches(created,item); index[PathOf(created)]=created;
    return created;
  }
  public object Apply(Dictionary<string,object> request) {
    Keys(request,"planId");
    string id=Text(request,"planId",true); Plan plan;
    if(!plans.TryGetValue(id,out plan)) throw new InvalidOperationException("Unknown or expired model preview");
    var index=Index(); var current=Snapshot(index);
    if(plan.Result!=null) { Preserve(plan.After,current,true); var repeated=new Dictionary<string,object>((Dictionary<string,object>)plan.Result); repeated["replayed"]=true; repeated["mutationsPerformed"]=false; repeated["addedModelNodes"]=0; return repeated; }
    if(plan.Started) throw new InvalidOperationException("This plan has partial or unknown effects; inspect before creating another plan");
    Preserve(plan.Before,current,true);
    plan.Started=true;
    // Register definitions first, allowing acyclic references to another new definition in this plan.
    foreach(var addition in plan.Additions) if(addition.Item.Kind=="struct") Create(addition.Parent,addition.Item,index);
    foreach(var addition in plan.Additions) {
      var created=Create(addition.Parent,addition.Item,index);
      foreach(var member in addition.Item.Members) Create(created,member,index);
    }
    var after=Index(); plan.After=Snapshot(after); Preserve(plan.Before,plan.After,false);
    var readback=new List<object>();
    foreach(var addition in plan.Additions) {
      var node=Child(addition.Parent,addition.Item.Name); Matches(node,addition.Item); readback.Add(Describe(node));
      foreach(var member in addition.Item.Members) { var child=Child(node,member.Name); Matches(child,member); readback.Add(Describe(child)); }
    }
    plan.Result=new Dictionary<string,object>{{"planId",id},{"readback",readback},{"protectedExistingNodes",plan.Before.Count},{"addedModelNodes",after.Count-plan.Before.Count},{"mutationsPerformed",after.Count!=plan.Before.Count},{"replayed",false},{"saved",false},{"exported",false},{"physicalOperations",false}};
    return plan.Result;
  }
}
