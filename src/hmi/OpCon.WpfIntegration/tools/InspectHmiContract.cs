using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Web.Script.Serialization;

// Metadata and call-site inspection only. Never creates a control or starts VisiWin.
internal static class InspectHmiContract
{
  private static readonly Dictionary<short, OpCode> Opcodes = typeof(OpCodes)
    .GetFields(BindingFlags.Public | BindingFlags.Static)
    .Where(f => f.FieldType == typeof(OpCode))
    .Select(f => (OpCode)f.GetValue(null)).ToDictionary(o => o.Value);

  private static string Signature(MemberInfo member)
  { return member.DeclaringType.FullName + "." + member; }

  private static string Description(MemberInfo member)
  {
    var attribute = member.GetCustomAttributes(typeof(DescriptionAttribute), true)
      .Cast<DescriptionAttribute>().FirstOrDefault();
    return attribute == null ? "" : attribute.Description;
  }

  private static object Calls(MethodInfo method)
  {
    var body = method.GetMethodBody();
    if (body == null) return new string[0];
    var bytes = body.GetILAsByteArray();
    var calls = new List<string>();
    for (int i = 0; i < bytes.Length;)
    {
      short value = bytes[i++];
      if (value == 0xfe) value = (short)(0xfe00 | bytes[i++]);
      OpCode opcode;
      if (!Opcodes.TryGetValue(value, out opcode)) throw new InvalidDataException("Unknown IL opcode");
      int size;
      switch (opcode.OperandType)
      {
        case OperandType.InlineNone: size = 0; break;
        case OperandType.ShortInlineBrTarget:
        case OperandType.ShortInlineI:
        case OperandType.ShortInlineVar: size = 1; break;
        case OperandType.InlineVar: size = 2; break;
        case OperandType.InlineI8:
        case OperandType.InlineR: size = 8; break;
        case OperandType.InlineSwitch: size = 4 + BitConverter.ToInt32(bytes, i) * 4; break;
        default: size = 4; break;
      }
      if (opcode.OperandType == OperandType.InlineMethod)
      {
        var called = method.Module.ResolveMethod(BitConverter.ToInt32(bytes, i),
          method.DeclaringType.GetGenericArguments(), method.GetGenericArguments());
        calls.Add(Signature(called));
      }
      i += size;
    }
    return calls.Distinct().ToArray();
  }

  public static int Main(string[] args)
  {
    try
    {
      string sdk = Path.GetFullPath(args[0]);
      AppDomain.CurrentDomain.AssemblyResolve += (s, e) =>
      {
        string file = Path.Combine(sdk, new AssemblyName(e.Name).Name + ".dll");
        return File.Exists(file) ? Assembly.LoadFrom(file) : null;
      };
      var names = new HashSet<string>(new[] {
        "Mod_ManualFunctionKey", "Mod_Button", "Mod_VarIn", "Mod_VarOut", "SmartControl",
        "OpconUnit", "ModeHandler", "ManualFunction", "ManualFunctionWorker", "Key",
        "VarIn", "Item", "DigitalItem", "LanguageManager", "LocalizedText", "MultiItemActivator",
        "ButtonBase", "ControlBase", "SmartUserControl", "SafetyTimer", "IModeHandler",
        "IShopfloorApp", "IShopfloorAppV2", "AppControlElementBase", "IAppConfigurationAdapter",
        "AuthorizationObject", "EditStates", "VerifyEditValueEventArgs", "VerifyDigitalEditValueEventArgs",
        "IAppResourceAdapter", "IProxyProviderService", "ActionDescription", "NumEdit",
        "DataConnector", "ConditionData", "IBelongToUnit"
      });
      var assemblies = new[] {
        "VisiWinNET.Embedded.Forms.dll", "VisiWinNET.Embedded.Systems.dll",
        "OpCon.HMI.Modulo.Shared.dll", "OpCon.HMI.Modulo.Forms.dll", "OpCon.ShopfloorApp.Contract.dll"
      }.Select(n => Assembly.LoadFrom(Path.Combine(sdk, n))).ToArray();
      var types = new List<object>();
      foreach (Type type in assemblies.SelectMany(a => a.GetExportedTypes()).Where(t => names.Contains(t.Name)))
      {
        const BindingFlags flags = BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static;
        var methods = type.GetMethods(flags | BindingFlags.NonPublic | BindingFlags.DeclaredOnly)
          .Where(m => !m.IsSpecialName && (m.IsPublic || m.IsFamily || m.IsFamilyOrAssembly))
          .Select(m => new { signature = m.ToString(), access = m.IsPublic ? "public" : "protected",
            calls = new[] { "OnMouseDown", "OnMouseUp", "PerformClick", "AttachItems", "DetachItems", "OnKeyDown", "OnKeyUp",
              "OnLostFocus", "OnEndInit", "StartEdit", "StopEdit", "GetModeHandlerForTokenHandling", "GetUnitForDisabledHandling",
              "OnVerifyEditValue", "OnEditStateChange", "OnEnter", "OnLeave", "OnGotFocus", "OnTextChanged",
              "OnDown", "OnUp" }
              .Contains(m.Name) ? Calls(m) : new string[0] }).ToArray();
        types.Add(new {
          name = type.FullName, assembly = type.Assembly.GetName().Name, isSealed = type.IsSealed,
          baseType = type.BaseType == null ? null : type.BaseType.FullName,
          interfaces = type.GetInterfaces().Select(t => t.FullName).ToArray(),
          properties = type.GetProperties(flags).Where(p => p.DeclaringType.Assembly != typeof(object).Assembly &&
            !p.DeclaringType.Namespace.StartsWith("System"))
            .Select(p => new { name = p.Name, type = p.PropertyType.FullName,
              read = p.GetGetMethod() != null, write = p.GetSetMethod() != null,
              owner = p.DeclaringType.FullName, description = Description(p),
              // Public accessor call sites only: inspect metadata, never invoke a setter.
              setterCalls = p.Name == "Text" && p.GetSetMethod() != null ? Calls(p.GetSetMethod()) : new string[0]
            }).ToArray(),
          events = type.GetEvents(flags).Where(e => e.DeclaringType.Namespace != null &&
            !e.DeclaringType.Namespace.StartsWith("System"))
            .Select(e => new { name = e.Name, type = e.EventHandlerType.FullName }).ToArray(),
          methods = methods
        });
      }
      var evidence = new {
        metadataOnly = true, plcContacted = false,
        assemblies = assemblies.Select(a => new { name = a.GetName().Name,
          assemblyVersion = a.GetName().Version.ToString(),
          fileVersion = System.Diagnostics.FileVersionInfo.GetVersionInfo(a.Location).FileVersion }).ToArray(),
        types = types
      };
      var json = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue }.Serialize(evidence);
      File.WriteAllText(args[1], json, new System.Text.UTF8Encoding(false));
      Console.WriteLine("Metadata types: " + types.Count + "; no controls or driver started.");
      return 0;
    }
    catch (Exception e) { Console.Error.WriteLine(e); return 1; }
  }
}
