using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

// Named controls use fresh accessibility queries. The unnamed Parse button is
// pinned to the observed V5.11 engineering bar; changing that bar needs calibration.
public static class CpStudioUi
{
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
    public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra;
  }
  [StructLayout(LayoutKind.Sequential)] struct INPUT {
    public uint type; public MOUSEINPUT mouse;
  }
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  delegate bool EnumWindowCallback(IntPtr h, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint command);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT rectangle);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder name, int size);
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] input, int size);
  [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder text, int length, out int needed);

  public sealed class Node {
    public string Name, Id, Type, Value, Help, AccessKey, Patterns; public bool Enabled, Offscreen;
  }
  public sealed class WindowInfo {
    public string Name; public int Pid, Handle; public bool Enabled, Modal;
  }
  static Exception invokeError;
  static CpStudioUi() { SetProcessDPIAware(); }
  static int activeInvocations;
  static readonly Dictionary<string, WindowInfo> boundWindows = new Dictionary<string, WindowInfo>();
  public static bool IsInvoking { get { return Interlocked.CompareExchange(ref activeInvocations, 0, 0) != 0; } }

  static void Act(Action action) {
    invokeError = null;
    Interlocked.Increment(ref activeInvocations);
    var worker = new Thread(() => { try { action(); } catch (Exception e) { invokeError=e; } finally { Interlocked.Decrement(ref activeInvocations); } });
    worker.IsBackground = true; worker.Start(); Thread.Sleep(180);
    if (invokeError != null) throw new InvalidOperationException("UI invocation failed.", invokeError);
  }

  static void Invoke(AutomationElement element) {
    object pattern;
    if (!element.Current.IsEnabled || !element.TryGetCurrentPattern(InvokePattern.Pattern, out pattern))
      throw new InvalidOperationException("Control cannot be invoked.");
    Act(() => ((InvokePattern)pattern).Invoke());
  }

  public static void RequireDesktop() {
    if (invokeError != null) throw new InvalidOperationException("The preceding UI invocation failed.", invokeError);
    IntPtr desktop = OpenInputDesktop(0, false, 1);
    if (desktop == IntPtr.Zero) throw new InvalidOperationException("Desktop is locked or inaccessible. Unlock Windows first.");
    try {
      int needed; var name = new StringBuilder(128);
      if (!GetUserObjectInformation(desktop, 2, name, 256, out needed) || name.ToString() != "Default")
        throw new InvalidOperationException("Desktop is locked or is not the interactive desktop.");
    } finally { CloseDesktop(desktop); }
  }

  static AutomationElement Root(string title) {
    RequireDesktop();
    WindowInfo binding;
    if (boundWindows.TryGetValue(title, out binding)) {
      var window = AutomationElement.FromHandle(new IntPtr(binding.Handle));
      var current = window.Current;
      if (current.ProcessId != binding.Pid || current.NativeWindowHandle != binding.Handle)
        throw new InvalidOperationException("The bound engineering window was replaced.");
      // Check the full native caption; never search for a different project.
      string actual = current.Name.Replace(".project* -", ".project -");
      if (actual != title) throw new InvalidOperationException("The bound project caption changed: " + current.Name);
      return window;
    }
    Condition caption = new PropertyCondition(AutomationElement.NameProperty, title);
    // PLE adds '*' after .project while the existing user project is dirty.
    // Keep the full path fixed and allow only that documented dirty marker.
    const string suffix = ".project - ctrlX PLC Engineering";
    if (title.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
      caption = new OrCondition(caption, new PropertyCondition(AutomationElement.NameProperty,
        title.Substring(0, title.Length - suffix.Length) + ".project* - ctrlX PLC Engineering"));
    var matches = AutomationElement.RootElement.FindAll(TreeScope.Children,
      caption);
    if (matches.Count != 1) throw new InvalidOperationException("Expected exactly one window: " + title + "; found " + matches.Count);
    var selected = matches[0].Current;
    boundWindows[title] = new WindowInfo {Name=title, Pid=selected.ProcessId, Handle=selected.NativeWindowHandle};
    return matches[0];
  }

  public static WindowInfo Describe(string title) {
    var root = Root(title); var c = root.Current;
    return new WindowInfo { Name = c.Name, Pid = c.ProcessId, Handle = c.NativeWindowHandle, Enabled = IsWindowEnabled(new IntPtr(c.NativeWindowHandle)) };
  }

  static IEnumerable<AutomationElement> Surfaces(AutomationElement root) {
    var windows = new List<AutomationElement>(); windows.Add(root);
    IntPtr rootHandle=new IntPtr(root.Current.NativeWindowHandle);
    uint rootPid=(uint)root.Current.ProcessId;
    EnumWindows((handle, data) => {
      uint pid; GetWindowThreadProcessId(handle, out pid);
      if (handle==rootHandle || pid!=rootPid || !IsWindowVisible(handle)) return true;
      IntPtr owner=GetWindow(handle, 4);
      while (owner!=IntPtr.Zero && owner!=rootHandle) owner=GetWindow(owner, 4);
      if (owner==rootHandle) windows.Add(AutomationElement.FromHandle(handle));
      return true;
    }, IntPtr.Zero);
    return windows;
  }

  static AutomationElement Direct(AutomationElement parent, string id) {
    return parent.FindFirst(TreeScope.Children, new PropertyCondition(AutomationElement.AutomationIdProperty, id));
  }

  static IEnumerable<AutomationElement> SearchSurfaces(AutomationElement root, string type) {
    bool ple = root.Current.Name.EndsWith(" - ctrlX PLC Engineering", StringComparison.Ordinal);
    if (!ple) {
      var top = Direct(root, "barTopDockSite");
      if (top != null) yield return top;
      var messages = Direct(root, "DockHost_{3d834a4e-aab7-4077-a4c2-aeee2d65082b}.ToolWindows[Messages]");
      if (messages != null) {
        var hosted = Direct(messages, "{3d834a4e-aab7-4077-a4c2-aeee2d65082b}.ToolWindows[Messages].WindowHostedControl");
        var view = hosted == null ? null : Direct(hosted, "MessagesView");
        var bar = view == null ? null : Direct(view, "tsMessages");
        if (bar != null) yield return bar;
      }
    }
    // File dialogs and menu popups are owned top-level surfaces; no scan through
    // the PLE device/source tree is necessary to find automation controls.
    foreach (var window in Surfaces(root))
      if (!Automation.Compare(window, root)) yield return window;
  }

  public static void Activate(string title) {
    var root=Root(title); IntPtr handle=new IntPtr(root.Current.NativeWindowHandle);
    if (IsIconic(handle)) ShowWindow(handle, 9);
    uint foregroundPid;
    GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
    if (foregroundPid == (uint)root.Current.ProcessId) return;
    root.SetFocus(); SetForegroundWindow(handle); Thread.Sleep(100);
    if (GetForegroundWindow() != handle) throw new InvalidOperationException("Could not focus the engineering window.");
  }

  public static WindowInfo[] Windows(string title) {
    var result = new List<WindowInfo>(); var root = Root(title);
    foreach (var window in Surfaces(root)) {
      object pattern; bool modal = false;
      if (window.TryGetCurrentPattern(WindowPattern.Pattern, out pattern)) modal = ((WindowPattern)pattern).Current.IsModal;
      var c = window.Current;
      if (c.NativeWindowHandle!=root.Current.NativeWindowHandle && c.ControlType==ControlType.Window && !IsWindowEnabled(new IntPtr(root.Current.NativeWindowHandle))) modal=true;
      result.Add(new WindowInfo {Name=c.Name, Pid=c.ProcessId, Handle=c.NativeWindowHandle, Enabled=IsWindowEnabled(new IntPtr(c.NativeWindowHandle)), Modal=modal});
    }
    return result.ToArray();
  }

  public static Node[] Read(string title) {
    var result = new List<Node>(); var root = Root(title);
    foreach (var surface in SearchSurfaces(root, "")) {
      var types = new ControlType[] { ControlType.Button, ControlType.MenuItem, ControlType.Edit, ControlType.CheckBox };
      var filters = new List<Condition>();
      foreach (var type in types) filters.Add(new PropertyCondition(AutomationElement.ControlTypeProperty, type));
      var all = surface.FindAll(TreeScope.Descendants, new AndCondition(new OrCondition(filters.ToArray()), new PropertyCondition(AutomationElement.IsOffscreenProperty, false)));
      foreach (AutomationElement element in all) {
        try {
          var c = element.Current; string value = ""; object pattern;
          if (element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) value = ((ValuePattern)pattern).Current.Value;
          var patterns = new List<string>();
          foreach (var supported in element.GetSupportedPatterns()) patterns.Add(supported.ProgrammaticName);
          result.Add(new Node {Name=c.Name, Id=c.AutomationId, Type=c.ControlType.ProgrammaticName.Replace("ControlType.", ""), Value=value, Help=c.HelpText, AccessKey=c.AccessKey, Patterns=string.Join(",", patterns.ToArray()), Enabled=c.IsEnabled, Offscreen=c.IsOffscreen});
        } catch (ElementNotAvailableException) { }
      }
    }
    return result.ToArray();
  }

  static List<AutomationElement> Controls(string title, string key, string type, bool useId) {
    var root = Root(title); var matches = new List<AutomationElement>();
    var property = useId ? AutomationElement.AutomationIdProperty : AutomationElement.NameProperty;
    foreach (var surface in SearchSurfaces(root, type)) {
      var all = surface.FindAll(TreeScope.Descendants, new AndCondition(new PropertyCondition(property, key),
        new PropertyCondition(AutomationElement.IsOffscreenProperty, false), new PropertyCondition(AutomationElement.IsEnabledProperty, true)));
      foreach (AutomationElement element in all) {
        var c = element.Current;
        if (c.IsOffscreen || !c.IsEnabled || (type != "" && c.ControlType.ProgrammaticName != "ControlType." + type)) continue;
        // WinForms may expose both a menu item and its native popup projection.
        // Equal live rectangles refer to one visible command; distinct targets
        // still fail the caller's exactly-one check.
        if (!matches.Exists(x => Automation.Compare(x, element) ||
          (x.Current.BoundingRectangle == c.BoundingRectangle && x.Current.Name == c.Name))) matches.Add(element);
      }
    }
    return matches;
  }

  public static int Count(string title, string key, string type, bool useId) {
    return Controls(title, key, type, useId).Count;
  }

  static AutomationElement Control(string title, string key, string type, bool useId) {
    var matches = Controls(title, key, type, useId);
    if (matches.Count != 1) throw new InvalidOperationException("Expected one visible " + type + " '" + key + "'; found " + matches.Count);
    if (!matches[0].Current.IsEnabled) throw new InvalidOperationException("Control is disabled: " + key);
    return matches[0];
  }

  public static void Click(string title, string name, string type) {
    if (type != "Button") throw new InvalidOperationException("Only named buttons use UIA Invoke.");
    // Observe completion in the caller: some native commands hold Invoke until
    // their file dialog/script has finished.
    Invoke(Control(title, name, type, false));
  }

  public static void Parse(string title) {
    Activate(title);
    var root = Root(title);
    var top = Direct(root, "barTopDockSite");
    if (top == null) throw new InvalidOperationException("CpStudio toolbar dock is unavailable.");
    var bar = top.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty,
      "{3d834a4e-aab7-4077-a4c2-aeee2d65082b}.Toolbars[e2c0f821-cc69-4ac0-836f-da61fd65ed53]"));
    if (bar.Count != 1) throw new InvalidOperationException("V5.11 engineering toolbar is missing or was customized.");
    var buttons = bar[0].FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
    if (buttons.Count != 8 || buttons[7].Current.Name != "Toolbars")
      throw new InvalidOperationException("Engineering toolbar layout needs calibration.");
    // Confirmed against V5.11 help and the live "Parse PLC code" tooltip:
    // Validate, Export, Parse, PLC code check, Object versions, Reload,
    // Simulation, Toolbars. Prefer a named command if Bosch adds one.
    Invoke(buttons[2]);
  }

  public static void Key(string title, byte key) {
    SendKey(title, key, false);
  }

  public static void AltKey(string title, byte key) {
    SendKey(title, key, true);
  }

  static void SendKey(string title, byte key, bool alt) {
    var root = Root(title); IntPtr handle = new IntPtr(root.Current.NativeWindowHandle);
    if (!IsWindowEnabled(handle)) throw new InvalidOperationException("Target window is blocked by a dialog.");
    foreach (int modifier in new int[] {16,17,18,91,92})
      if ((GetAsyncKeyState(modifier) & 0x8000) != 0) throw new InvalidOperationException("Release modifier keys before running automation.");
    if (IsIconic(handle)) ShowWindow(handle, 9);
    uint foregroundPid;
    GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
    // Native menu popups may own foreground focus. Keep that focus while
    // sending the next mnemonic; focusing the editor would consume the key.
    if (foregroundPid != (uint)root.Current.ProcessId) SetForegroundWindow(handle);
    Thread.Sleep(350);
    GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
    if (foregroundPid != (uint)root.Current.ProcessId) throw new InvalidOperationException("Could not focus the intended project window.");
    if (alt) keybd_event(0x12, 0, 0, UIntPtr.Zero);
    try { keybd_event(key, 0, 0, UIntPtr.Zero); keybd_event(key, 0, 2, UIntPtr.Zero); }
    finally { if (alt) keybd_event(0x12, 0, 2, UIntPtr.Zero); }
  }

  public static void SetText(string title, string key, string value, bool useId) {
    var element = Control(title, key, "Edit", useId); object pattern;
    if (!element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) throw new InvalidOperationException("Edit has no ValuePattern: " + key);
    var editor = (ValuePattern)pattern;
    if (editor.Current.IsReadOnly) throw new InvalidOperationException("Edit is read-only: " + key);
    editor.SetValue(value);
    if (editor.Current.Value != value) throw new InvalidOperationException("Text readback failed: " + key);
  }

}
