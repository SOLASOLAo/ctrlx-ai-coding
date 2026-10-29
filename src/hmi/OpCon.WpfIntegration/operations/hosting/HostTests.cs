using System;
using System.Collections;
using System.ComponentModel;
using System.ComponentModel.Design;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using System.Xml;
using OpCon.WpfIntegration.Operations;
using OpCon.WpfIntegration.Operations.Hosting;
using Forms = System.Windows.Forms;

internal static class HostTests
{
  private static int checks;
  private static string sdk, loaderPath;
  private static void Check(bool condition, string name)
  { if (!condition) throw new InvalidOperationException(name); checks++; Console.WriteLine("PASS " + name); }

  // Does not activate the desktop or synthesize OS input. Raised lifecycle events
  // below exercise the managed host path only, not real Alt+Tab/touch acceptance.
  private sealed class TestForm : Forms.Form
  {
    protected override bool ShowWithoutActivation { get { return true; } }
    public void NotifyActivated() { OnActivated(EventArgs.Empty); }
    public void NotifyDeactivated() { OnDeactivate(EventArgs.Empty); }
    public void NotifyClosingCancelled()
    { OnFormClosing(new Forms.FormClosingEventArgs(Forms.CloseReason.UserClosing, true)); }
    public TestForm()
    {
      ShowInTaskbar = false; StartPosition = Forms.FormStartPosition.Manual;
      Location = new System.Drawing.Point(-16000, -16000);
      ClientSize = new System.Drawing.Size(1000, 650);
    }
  }
  private static void Pump()
  {
    Forms.Application.DoEvents();
    Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => {}));
  }
  private static TextBox Editor(WpfParameterBox control)
  { control.ApplyTemplate(); return (TextBox)control.Template.FindName("PART_Editor", control); }
  private static void BeginEdit(WpfParameterBox control)
  {
    var editor = Editor(control);
    editor.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(editor), 0, Key.Enter) {
      RoutedEvent = Keyboard.PreviewKeyDownEvent
    });
  }

  [STAThread]
  private static int Main(string[] args)
  {
    try {
      sdk = args[0]; loaderPath = args[1];
      AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
        var name = new AssemblyName(e.Name).Name + ".dll";
        foreach (string directory in new[] {sdk, Path.GetDirectoryName(loaderPath)}) {
          string file = Path.Combine(directory, name);
          if (File.Exists(file)) return Assembly.LoadFrom(file);
        }
        return null;
      };
      Assembly.LoadFrom(loaderPath);
      CheckNativeLoader();
      CheckHostLifecycle();
      Console.WriteLine("EMBEDDING_ONLY passed=" + checks +
        "; nativeLoader=true; driverStarted=false; plcContacted=false; nativeOperationAdapter=false; runtimeAcceptance=false");
      return 0;
    }
    catch (Exception error) { Console.Error.WriteLine(error); return 1; }
  }

  [MethodImpl(MethodImplOptions.NoInlining)]
  private static void CheckNativeLoader()
  {
    var previous = LicenseManager.CurrentContext;
    LicenseManager.CurrentContext = new DesigntimeLicenseContext();
    try {
      foreach (string name in new[] {"VisiWinNET.Embedded.Systems.dll", "VisiWinNET.Embedded.Forms.dll",
        "OpCon.HMI.Modulo.Shared.dll"}) Assembly.LoadFrom(Path.Combine(sdk, name));
      using (var registered = new WpfInputHost()) {
        var loader = new VisiWinNET.Smart.SFCLoader();
        var errors = new ArrayList();
        using (var reader = new XmlTextReader(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "OperationsPage.sfc")))
        using (var page = (Forms.Control)loader.Load(reader, new Hashtable(), null, errors)) {
          Check(errors.Count == 0 && page != null, "matching native SFCLoader loads the owned page without errors");
          var host = loader.Find("OperationView") as WpfInputHost;
          Check(host != null && Object.ReferenceEquals(host.Parent, page), "native page owns the WPF host directly");
          Check(host.LayoutFile == "HostedOperations.xaml" && host.Width == 944 && host.Height == 572,
            "native loader reads public layout and geometry configuration");
          Check(page.Controls.Count == 1 && host.View == null && !host.InputActive,
            "design loading neither instantiates operation controls nor enables input");
        }
      }
    }
    finally { LicenseManager.CurrentContext = previous; }
  }

  private static void CheckHostLifecycle()
  {
    var journal = new InputJournal();
    var port = new ProbeParameterPort(journal, "Local.UnitA.Setpoint");
    var holdPort = new ProbeManualPort(journal, "Local.UnitA.Hold");
    using (var form = new TestForm())
    using (var host = new WpfInputHost { LayoutFile = "HostedOperations.xaml", Dock = Forms.DockStyle.Fill }) {
      form.Controls.Add(host);
      form.Show(); Pump();
      Check(host.LastError == null && host.View != null, "real ElementHost loads WPF and its relative resource dictionary");
      var parameter = (WpfParameterBox)host.View.FindName("Setpoint");
      var hold = (WpfManualKey)host.View.FindName("Hold");
      Check(parameter != null && hold != null && Window.GetWindow(parameter) == null,
        "embedded visible controls are WPF without a WPF Window");
      Check(!Editor(parameter).IsEnabled && !hold.IsEnabled && parameter.ObservedValue == "—",
        "unbound host keeps parameters unknown and commands disabled");
      parameter.Operation = port; hold.Operation = holdPort; Pump();
      Check(journal.Count == 0 && port.SubscriberCount == 1 && holdPort.SubscriberCount == 1,
        "binding local test ports subscribes without generating input");
      form.NotifyActivated(); Pump();
      Check(host.InputActive && Editor(parameter).IsEnabled && journal.Count == 0,
        "WinForms activation opens only the local gate without beginning an edit");
      BeginEdit(parameter);
      Check(port.Begins == 1 && !Editor(parameter).IsReadOnly, "embedded WPF editor starts one local edit" +
        " (begins=" + port.Begins + ", cancels=" + port.Cancels + ", loaded=" + parameter.IsLoaded +
        ", visible=" + parameter.IsVisible + ", enabled=" + parameter.IsEnabled +
        ", readonly=" + Editor(parameter).IsReadOnly + ")");
      form.NotifyDeactivated(); Pump();
      Check(!host.InputActive && port.Cancels == 1 && port.Submits == 0,
        "WinForms deactivation cancels the edit without submitting");
      int before = journal.Count;
      form.NotifyActivated(); Pump();
      Check(journal.Count == before && Editor(parameter).IsReadOnly, "activation does not replay the cancelled edit");
      BeginEdit(parameter); host.Hide(); Pump();
      Check(port.Cancels == 2 && port.Submits == 0, "host Hide cancels its edit once");
      before = journal.Count;
      host.Show(); Pump();
      Check(journal.Count == before, "host Show does not replay input");
      BeginEdit(parameter); host.Enabled = false; Pump();
      Check(port.Cancels == 3 && !host.InputActive, "disabled host cancels input and closes its own gate");
      host.Enabled = true; Pump();
      BeginEdit(parameter); form.NotifyClosingCancelled(); Pump();
      Check(port.Cancels == 4 && host.InputActive && Editor(parameter).IsReadOnly,
        "cancelled WinForms close leaves no draft and permits only new input");
      before = journal.Count;
      parameter.CancelInput("repeat cancellation"); hold.CancelInput("nothing held");
      Check(journal.Count == before, "repeated cancellation and an unheld key have no extra input");
      BeginEdit(parameter);
      host.Dispose(); Pump();
      Check(port.Cancels == 5 && port.Submits == 0 && port.SubscriberCount == 0 && holdPort.SubscriberCount == 0,
        "disposing an embedded view cancels and releases its own subscriptions");
      before = journal.Count;
      form.NotifyDeactivated(); form.NotifyActivated(); Pump();
      Check(journal.Count == before, "disposed host no longer handles owner lifecycle");
      form.Close();
    }
    var other = new ProbeParameterPort(journal, "Local.UnitB.Setpoint");
    using (var form = new TestForm())
    using (var first = new WpfInputHost { LayoutFile = "HostedOperations.xaml", Width = 480 })
    using (var second = new WpfInputHost { LayoutFile = "HostedOperations.xaml", Left = 490, Width = 480 }) {
      form.Controls.Add(first); form.Controls.Add(second);
      form.Show(); Pump();
      var a = (WpfParameterBox)first.View.FindName("Setpoint");
      var b = (WpfParameterBox)second.View.FindName("Setpoint");
      a.Operation = port; b.Operation = other;
      form.NotifyActivated(); Pump();
      int cancels = port.Cancels;
      BeginEdit(a); BeginEdit(b); first.Hide(); Pump();
      Check(port.Cancels == cancels + 1 && other.Cancels == 0 && !Editor(b).IsReadOnly,
        "hiding one instance cancels its captured port and preserves the other edit");
      first.Dispose(); Pump();
      Check(port.SubscriberCount == 0 && other.SubscriberCount == 1,
        "disposing one instance does not unsubscribe another instance");
      form.NotifyDeactivated(); Pump();
      Check(other.Cancels == 1 && other.Submits == 0, "owner deactivation cancels the remaining instance");
      form.Close(); Pump();
    }
    using (var form = new TestForm())
    using (var bad = new WpfInputHost { LayoutFile = "../outside.xaml" }) {
      form.Controls.Add(bad); form.Show(); Pump(); form.NotifyActivated();
      Check(bad.View == null && bad.LastError != null && !bad.InputActive,
        "invalid layout path remains disabled with an explicit error");
      form.Close();
    }
    string invalidRoot = Guid.NewGuid().ToString("N") + ".xaml";
    string invalidFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, invalidRoot);
    File.WriteAllText(invalidFile, "<Window xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" />");
    try {
      using (var form = new TestForm())
      using (var bad = new WpfInputHost { LayoutFile = invalidRoot }) {
        form.Controls.Add(bad); form.Show(); Pump();
        form.NotifyActivated(); bad.Hide(); bad.Show(); Pump();
        Check(bad.View == null && bad.LastError != null && !bad.InputActive,
          "rejected Window root cannot reopen the input gate after activation or visibility changes");
        form.Close();
      }
    }
    finally { File.Delete(invalidFile); }
  }
}
