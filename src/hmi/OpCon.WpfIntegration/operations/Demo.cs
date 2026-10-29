using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Threading;
using OpCon.WpfIntegration.Operations;

internal static class Demo
{
  [STAThread]
  private static int Main(string[] args)
  {
    try {
      if (args.Any(a => a != "--input-probe" && a != "--self-check"))
        throw new ArgumentException("Usage: OpCon.WpfOperations.Sample.exe [--input-probe] [--self-check]");
      var app = new Application();
      var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Demo.xaml");
      Window window;
      using (var stream = File.OpenRead(path))
        window = (Window)XamlReader.Load(stream, new ParserContext { BaseUri = new Uri(path) });
      bool localProbe = args.Contains("--input-probe");
      var journal = localProbe ? AttachProbe(window) : null;
      if (args.Contains("--self-check")) {
        window.ShowActivated = false; window.ShowInTaskbar = false; window.Left = -16000; window.Top = -16000;
        window.ContentRendered += (s, e) => window.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => {
          try {
            var parameter = (WpfParameterBox)window.FindName("Setpoint");
            var hold = (WpfManualKey)window.FindName("Hold");
            if (localProbe) {
              if (parameter.Operation == null || hold.Operation == null || journal.Count != 0 ||
                parameter.Operation.State.Origin != OperationOrigin.LocalInputProbe || !hold.IsEnabled)
                throw new InvalidOperationException("Local probe startup failed.");
            }
            else if (parameter.Operation != null || hold.Operation != null || hold.IsEnabled || parameter.ObservedValue != "—")
              throw new InvalidOperationException("Default page is not disabled/unknown.");
            Console.WriteLine("SAMPLE_STARTUP_ONLY mode=" + (localProbe ? "local-input-probe" : "disabled") +
              "; initialIntents=0; nativeAdapterInvoked=false; plcContacted=false");
            window.Close();
          }
          catch (Exception error) { Console.Error.WriteLine(error); app.Shutdown(1); }
        }));
      }
      return app.Run(window);
    }
    catch (Exception error) { Console.Error.WriteLine(error); return 1; }
  }

  internal static InputJournal AttachProbe(Window window)
  {
    var journal = new InputJournal();
    var parameter = new ProbeParameterPort(journal, "Probe.UnitA.Parameters.Setpoint");
    var pulse = new ProbeManualPort(journal, "Probe.UnitA.ManualFunctions.Pulse");
    var hold = new ProbeManualPort(journal, "Probe.UnitA.ManualFunctions.Hold");
    ((WpfParameterBox)window.FindName("Setpoint")).Operation = parameter;
    ((WpfManualKey)window.FindName("Pulse")).Operation = pulse;
    ((WpfManualKey)window.FindName("Hold")).Operation = hold;
    ((TextBlock)window.FindName("ModeBanner")).Text = "本地输入探针已开启：仅记录输入意图。无原生操作适配器、无 PLC 连接；12.5 是示例值。";
    var entries = (ListBox)window.FindName("Journal");
    journal.Changed += (s, e) => {
      entries.ItemsSource = journal.Entries.ToArray();
      ((TextBlock)window.FindName("JournalTitle")).Text = "本地输入记录：" + journal.Count + "  ·  PLC 接收、扫描周期及执行结果：未测量";
      if (entries.Items.Count > 0) entries.ScrollIntoView(entries.Items[entries.Items.Count - 1]);
    };
    bool available = true;
    var toggle = (Button)window.FindName("ToggleAvailability"); toggle.IsEnabled = true;
    toggle.Click += (s, e) => {
      available = !available;
      parameter.SetAvailable(available, available); pulse.SetAvailable(available, available); hold.SetAvailable(available, available);
    };
    return journal;
  }
}
