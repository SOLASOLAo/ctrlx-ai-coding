using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using OpCon.WpfIntegration;
using Forms = System.Windows.Forms;

internal static class ComponentTests
{
  private static int count;
  private static string layoutFile;
  private static void Check(bool condition, string name)
  { if (!condition) throw new InvalidOperationException(name); count++; Console.WriteLine("PASS " + name); }
  private static void Reject(Action action, string name)
  {
    try { action(); }
    catch (ArgumentException) { count++; Console.WriteLine("PASS " + name); return; }
    throw new InvalidOperationException("Did not reject: " + name);
  }

  [STAThread]
  private static int Main(string[] args)
  {
    try
    {
      AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
        string file = Path.Combine(args[0], new AssemblyName(e.Name).Name + ".dll");
        return File.Exists(file) ? Assembly.LoadFrom(file) : null;
      };
      layoutFile = args[1]; Run();
      Console.WriteLine("OFFLINE_ONLY passed=" + count + "; plcContacted=false; runtimeAcceptance=false");
      return 0;
    }
    catch (Exception error) { Console.Error.WriteLine(error); return 1; }
  }

  private static void Run()
  {
    var gate = new FreshnessGate();
    Check(!gate.Observe(8u, true, 0, 2000), "initial cached heartbeat is unknown");
    Check(!gate.Observe(8u, true, 250, 2000), "unchanged cached heartbeat remains unknown");
    Check(gate.Observe(9u, true, 500, 2000), "observed heartbeat change permits fresh display");
    Check(gate.Observe(9u, true, 2500, 2000), "freshness exact deadline");
    Check(!gate.Observe(9u, true, 2501, 2000), "frozen heartbeat expires");
    Check(!gate.Observe(10u, false, 2750, 2000), "bad driver quality invalidates");
    Check(!gate.Observe(10u, true, 3000, 2000), "reconnect does not trust first cache");
    Check(gate.Observe(11u, true, 3250, 2000), "reconnect requires a new observed change");
    gate.Reset();
    Check(!gate.Observe(20u, true, 4000, 2000), "page reopen starts unknown");
    Check(gate.Observe(21u, true, 4250, 2000), "reopened page fresh after new change");
    Check(!gate.Observe(21u, true, 4000, 2000), "backwards time cannot grant freshness");
    gate.Reset(); gate.Observe(UInt32.MaxValue, true, 0, 2000);
    Check(gate.Observe(0u, true, 100, 2000), "heartbeat counter wrap is an observed change");
    Check(!gate.Observe(30u, true, 3000, 2000), "first sample after a long UI pause stays unknown");
    Check(gate.Observe(31u, true, 3250, 2000), "UI recovery requires a subsequent heartbeat change");
    Check(NativeReadSet.FullName("UnitA.", "Status.Count") == "UnitA.Status.Count", "prefix resolves once");
    Check(NativeReadSet.FullName("UnitB", "Status.Count") != NativeReadSet.FullName("UnitA", "Status.Count"), "instance bindings remain distinct");
    Reject(() => NativeReadSet.FullName("", "Status"), "empty instance prefix");
    Reject(() => NativeReadSet.FullName("Unit", ".Status"), "absolute-like relative binding");
    Reject(() => NativeReadSet.FullName("Unit", "Status\nCount"), "control character binding");

    Check(NativePlacement.RectangleIsValid(new Point(10, 20), new Point(130, 20), new Point(10, 64), new Point(130, 64)), "rectangular native slot");
    Check(NativePlacement.RectangleIsValid(new Point(15, 30), new Point(195, 30), new Point(15, 96), new Point(195, 96)), "150 percent device-pixel geometry");
    Check(!NativePlacement.RectangleIsValid(new Point(10, 20), new Point(130, 25), new Point(5, 64), new Point(125, 69)), "rotated native slot rejected");
    Check(!NativePlacement.RectangleIsValid(new Point(10, 20), new Point(10, 20), new Point(10, 64), new Point(10, 64)), "zero width native slot rejected");
    Check(!NativePlacement.RectangleIsValid(new Point(Double.NaN, 20), new Point(130, 20), new Point(10, 64), new Point(130, 64)), "nonfinite native slot rejected");

    var slot = new Border(); NativeSlot.SetControlName(slot, "nativePulse");
    Check(NativeSlot.GetControlName(slot) == "nativePulse", "native slot configuration survives WPF property system");
    var value = new TextBlock(); NativeValue.SetPath(value, "Status.RequestCount"); NativeValue.SetFormat(value, "0");
    Check(NativeValue.GetPath(value) == "Status.RequestCount" && NativeValue.GetFormat(value) == "0", "display path and format configuration");
    NativeText.SetGroup(value, "IntegrationDemo"); NativeText.SetKey(value, "RequestCount");
    Check(NativeText.GetGroup(value) == "IntegrationDemo" && NativeText.GetKey(value) == "RequestCount", "native bilingual text configuration");

    using (var host = new WpfViewHost())
    {
      Check(!host.IsFresh && host.ActiveItemCount == 0, "constructing host starts no native subscriptions");
      Reject(() => host.HeartbeatTimeoutMs = 499, "heartbeat timeout lower bound");
      Reject(() => host.HeartbeatTimeoutMs = 30001, "heartbeat timeout upper bound");
      Check(!typeof(WpfViewHost).GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
        .Any(m => !m.IsSpecialName), "host exposes configuration and state without command methods");
    }
    using (var page = new Forms.Panel())
    using (var otherPage = new Forms.Panel())
    using (var firstHost = new WpfViewHost())
    using (var secondHost = new WpfViewHost())
    using (var control = new Forms.Button { Name = "geometryOnly", Bounds = new System.Drawing.Rectangle(2, 3, 120, 44) })
    {
      page.Controls.Add(firstHost); page.Controls.Add(secondHost); page.Controls.Add(control);
      var original = control.Bounds;
      using (var lease = new NativePlacement(firstHost, control, new Border()))
      {
        Check(control.Parent == page && control.Region != null && !control.TabStop, "presentation lease suppresses mouse and Tab input without reparenting");
        bool refused = false;
        try { using (new NativePlacement(secondHost, control, new Border())) { } }
        catch (InvalidOperationException) { refused = true; }
        Check(refused, "a second host cannot claim the same native control");
      }
      Check(control.Bounds == original && control.Region == null && control.TabStop, "lease disposal restores original geometry, region and Tab navigation");
      using (new NativePlacement(secondHost, control, new Border()))
      { Check(control.Parent == page, "released control can be claimed by its next presentation owner"); }
      using (var lease = new NativePlacement(firstHost, control, new Border()))
      {
        otherPage.Controls.Add(control);
        control.Bounds = new System.Drawing.Rectangle(300, 200, 100, 40);
      }
      Check(control.Bounds == new System.Drawing.Rectangle(300, 200, 100, 40), "cleanup does not overwrite a new parent owner's geometry");
    }
    using (var stream = File.OpenRead(layoutFile))
    {
      var layout = (Grid)XamlReader.Load(stream);
      foreach (var size in new[] { new Size(944, 572), new Size(800, 500), new Size(1280, 720) })
      {
        layout.Measure(size); layout.Arrange(new Rect(new Point(0, 0), size)); layout.UpdateLayout();
        var slots = layout.Children.OfType<Grid>().SelectMany(g => g.Children.OfType<Border>())
          .Where(b => !String.IsNullOrEmpty(NativeSlot.GetControlName(b))).ToArray();
        Check(slots.Length == 3 && slots.All(b => b.ActualWidth >= 200 && b.ActualHeight >= 40),
          "real WPF layout slots remain usable at " + size);
      }
    }
  }
}
