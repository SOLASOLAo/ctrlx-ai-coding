using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using OpCon.WpfIntegration.Operations;

internal static class Tests
{
  private static int passed;
  private static void Check(bool value, string name)
  { if (!value) throw new InvalidOperationException(name); passed++; Console.WriteLine("PASS " + name); }

  [STAThread]
  private static int Main(string[] args)
  {
    try {
      TestManual(); TestParameter();
      var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
      TestWpf(args[0], args.Length > 1 ? args[1] : null);
      app.Shutdown();
      Console.WriteLine("OFFLINE_INPUT_ONLY passed=" + passed + "; nativeAdapterInvoked=false; plcContacted=false; runtimeAcceptance=false");
      return 0;
    }
    catch (Exception error) { Console.Error.WriteLine(error); return 1; }
  }

  private static void TestManual()
  {
    var journal = new InputJournal();
    var a = new ProbeManualPort(journal, "Probe.UnitA.Hold");
    var b = new ProbeManualPort(journal, "Probe.UnitB.Hold");
    using (var input = new ManualInputSession()) {
      Check(!input.Begin(), "no adapter rejects press");
      input.Bind(a); Check(a.Begins == 0 && a.Ends == 0, "binding alone sends no input");
      Check(input.Begin() && input.IsPressed, "press enters a local input lifetime");
      Check(!input.Begin() && a.Begins == 1, "repeat down cannot create a second press");
      input.Cancel("release"); input.Cancel("duplicate release");
      Check(a.Begins == 1 && a.Ends == 1 && !input.IsPressed, "one release for one press");
      input.Begin(); input.Bind(b);
      Check(a.Ends == 2 && b.Ends == 0 && b.Begins == 0, "binding switch releases captured original endpoint only");
      input.Begin(); b.SetAvailable(false, false);
      Check(!input.IsPressed && b.Ends == 1 && !input.Begin(), "availability loss releases and blocks new input");
      b.SetAvailable(true, true);
      Check(!input.IsPressed && b.Begins == 1, "recovery sends no automatic press");
      input.Begin(); b.SetAvailable(true, true);
      Check(!input.IsPressed && b.Ends == 2, "generation change releases old input");
    }
    using (var input = new ManualInputSession()) {
      a.DuringBegin = () => a.SetAvailable(false, false); input.Bind(a);
      Check(!input.Begin() && a.Begins == 3 && a.Ends == 3, "reentrant denial during start still releases once");
      a.DuringBegin = null; a.SetAvailable(true, true); a.ThrowOnBegin = true;
      input.Begin();
      Check(!input.IsPressed && a.Ends == 4 && input.LastReceipt.Disposition == InputDisposition.Unknown,
        "unknown start receives one original-context release and keeps unknown result");
      a.ThrowOnBegin = false; Check(!input.Begin(), "unknown input cannot be retried in the same generation");
      a.SetAvailable(true, true); Check(input.Begin(), "new generation permits a new explicit press");
      a.ThrowOnEnd = true; input.Cancel("injected failure");
      int releases = a.Ends; input.Cancel("no retry");
      Check(a.Ends == releases && !input.Begin(), "unknown release is not replayed");
      a.ThrowOnEnd = false;
    }
    a.SetAvailable(true, true); a.DuringBegin = null;
    var disposable = new ManualInputSession(); disposable.Bind(a); disposable.Begin();
    int before = a.Ends; disposable.Dispose(); disposable.Dispose();
    Check(a.Ends == before + 1, "disposing a held input releases exactly once");
    Check(a.SubscriberCount == 0 && b.SubscriberCount == 0, "manual port subscriptions are released");
    Check(a.State.Origin == OperationOrigin.LocalInputProbe, "probe has no native-runtime success claim");
    using (var input = new ManualInputSession()) {
      input.Bind(a); input.Begin(); int ended = a.Ends;
      a.SetReadiness(false, true);
      Check(input.IsPressed && a.Ends == ended && !input.Begin(), "busy start gate does not cancel an allowed held input");
      input.Cancel("explicit release while busy");
      Check(a.Ends == ended + 1 && !input.Begin(), "release remains possible when new starts are prohibited");
    }
  }

  private static void TestParameter()
  {
    var journal = new InputJournal();
    var a = new ProbeParameterPort(journal, "Probe.UnitA.Setpoint");
    var b = new ProbeParameterPort(journal, "Probe.UnitB.Setpoint");
    using (var input = new ParameterInputSession()) {
      Check(!input.Begin(), "no adapter rejects editing");
      input.Bind(a); Check(a.Submits == 0, "parameter binding is read-only until explicit input");
      Check(input.Begin(), "explicit editing opens a local lifetime");
      Check(!input.Submit("101", CultureInfo.InvariantCulture) && a.Submits == 0, "upper limit rejects before dispatch");
      Check(!input.Submit("NaN", CultureInfo.InvariantCulture) && a.Submits == 0, "non-number rejects before dispatch");
      Check(!input.Submit("1,234", CultureInfo.InvariantCulture) && a.Submits == 0, "thousands separator is not silently reinterpreted");
      Check(input.Submit("23.75", CultureInfo.InvariantCulture) && a.LastSubmission == 23.75m, "decimal submission records exact local value");
      Check(!input.Submit("23.75", CultureInfo.InvariantCulture) && a.Submits == 1, "repeated submit has no second input lifetime");
      Check(a.State.Value == 12.5m, "local submission never masquerades as PLC readback");
      input.Begin(); input.Cancel("escape"); input.Cancel("duplicate escape");
      Check(a.Cancels == 1 && a.Submits == 1, "cancel sends no parameter submission");
      input.Begin(); a.SetAvailable(false, false);
      Check(!input.IsEditing && a.Cancels == 2 && a.State.Value == null, "bad availability cancels draft and shows unknown");
      a.SetAvailable(true, true); Check(a.Submits == 1, "recovery never submits the old draft");
      input.Begin(); input.Bind(b);
      Check(a.Cancels == 3 && b.Cancels == 0 && b.Submits == 0, "binding switch cancels original parameter endpoint only");
      input.Begin(); Check(input.Submit("12,75", CultureInfo.GetCultureInfo("de-DE")) && b.LastSubmission == 12.75m,
        "number parsing follows the configured WPF language culture");
      input.Begin(); b.SetAvailable(true, true);
      Check(!input.IsEditing && !input.Submit("99", CultureInfo.InvariantCulture), "new generation invalidates an unfinished draft");
    }
    using (var input = new ParameterInputSession()) {
      a.DuringBegin = () => a.SetAvailable(false, false); input.Bind(a);
      int before = a.Cancels; Check(!input.Begin() && a.Cancels == before + 1, "reentrant edit denial cancels once");
      a.DuringBegin = null; a.SetAvailable(true, true); a.ThrowOnSubmit = true;
      input.Begin(); Check(!input.Submit("24", CultureInfo.InvariantCulture), "unknown submission is not success");
      int submits = a.Submits; Check(!input.Begin() && a.Submits == submits, "unknown submission cannot be automatically replayed");
      a.ThrowOnSubmit = false; a.SetAvailable(true, true); Check(input.Begin(), "new generation requires a new explicit edit");
    }
    Check(a.SubscriberCount == 0 && b.SubscriberCount == 0, "parameter port subscriptions are released");
    Check(!new OperationState(new OperationContext("missing", 0), OperationOrigin.Unavailable, true, "").CanStart,
      "unavailable origin cannot claim operation readiness");
    Check(!new ParameterState(new OperationContext("unknown", 0), OperationOrigin.LocalInputProbe, true, "", null, 0, 10, "").CanStart,
      "unknown parameter value cannot start editing");
    using (var input = new ParameterInputSession()) {
      input.Bind(a); input.Begin(); a.SetReadiness(false, true);
      Check(input.IsEditing && input.Submit("25", CultureInfo.InvariantCulture), "existing edit can submit while new edit starts are busy");
      Check(!input.Begin(), "busy parameter port cannot begin another edit");
    }
  }

  private static void Pump()
  { Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { })); }
  private static Window Load(string directory)
  {
    string path = Path.Combine(directory, "Demo.xaml");
    using (var stream = File.OpenRead(path))
      return (Window)XamlReader.Load(stream, new ParserContext { BaseUri = new Uri(path) });
  }
  private static void InputEvent(TextBox editor)
  {
    // Synthetic WPF input intent: no OS focus change or physical mouse injection.
    editor.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) {
      RoutedEvent = Mouse.PreviewMouseDownEvent
    });
  }
  private static void KeyEvent(TextBox editor, Key key)
  {
    editor.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(editor), 0, key) {
      RoutedEvent = Keyboard.PreviewKeyDownEvent
    });
  }
  private static void TestWpf(string directory, string renderPath)
  {
    var window = Load(directory);
    var journal = new InputJournal();
    var parameterPort = new ProbeParameterPort(journal, "Probe.UnitA.Setpoint");
    var manualPort = new ProbeManualPort(journal, "Probe.UnitA.Hold");
    window.ShowActivated = false; window.ShowInTaskbar = false; window.Left = -16000; window.Top = -16000;
    try {
      window.Show(); Pump(); window.UpdateLayout();
      var parameter = (WpfParameterBox)window.FindName("Setpoint");
      var key = (WpfManualKey)window.FindName("Hold");
      var editor = (TextBox)parameter.Template.FindName("PART_Editor", parameter);
      var apply = (Button)parameter.Template.FindName("PART_Apply", parameter);
      Check(editor != null && apply != null, "actual WPF parameter template creates native WPF editor and buttons");
      Check(!editor.IsEnabled && !key.IsEnabled && parameter.ObservedValue == "—", "default page is disabled and unknown without native adapter");
      Check(!typeof(System.Windows.Controls.Primitives.ButtonBase).IsAssignableFrom(typeof(WpfManualKey)),
        "manual key is a WPF input control without Button Click semantics");
      Check(!typeof(WpfManualKey).Assembly.GetReferencedAssemblies().Any(a =>
        a.Name.StartsWith("VisiWin", StringComparison.Ordinal) || a.Name.Contains("Modulo") || a.Name == "System.Windows.Forms"),
        "WPF input DLL has no vendor or WinForms runtime dependency");
      parameter.Operation = parameterPort; key.Operation = manualPort; Pump();
      Check(editor.IsEnabled && key.IsEnabled && parameterPort.Begins == 0 && manualPort.Begins == 0,
        "binding a local probe enables WPF input without sending an operation");
      editor.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, null, editor) {
        RoutedEvent = Keyboard.GotKeyboardFocusEvent
      });
      Check(parameterPort.Begins == 0, "focus restoration alone cannot start parameter editing");
      InputEvent(editor); editor.Text = "23.75";
      apply.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, apply));
      Check(parameterPort.Submits == 1 && parameterPort.LastSubmission == 23.75m,
        "synthetic WPF input and confirm event dispatch one local submission");
      Check(parameter.ObservedValue == "12.5" && editor.Text == "12.5",
        "WPF observed value is not optimistically replaced by an input intent");
      apply.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, apply));
      Check(parameterPort.Submits == 1, "duplicate confirm event cannot resend a completed draft");
      InputEvent(editor); editor.Text = "77"; KeyEvent(editor, Key.Escape);
      Check(parameterPort.Cancels == 1 && parameterPort.Submits == 1 && editor.Text == "12.5",
        "WPF Escape cancels draft and restores the observed value");
      InputEvent(editor); editor.Text = "88"; window.Hide(); Pump();
      Check(parameterPort.Cancels == 2 && parameterPort.Submits == 1, "actual WPF Hide cancels an unfinished draft");
      window.Show(); Pump();
      Check(parameterPort.Begins == 3 && parameterPort.Submits == 1 && manualPort.Begins == 0,
        "WPF page recovery does not replay draft or manual input");
      parameterPort.SetAvailable(false, false); Pump();
      Check(parameter.ObservedValue == "—" && !editor.IsEnabled, "WPF unavailable value renders unknown and disables editing");
      parameterPort.SetAvailable(true, true); Pump();
      Check(parameterPort.Submits == 1, "new probe generation only refreshes display");
      ((WpfManualKey)window.FindName("Pulse")).Operation = new ProbeManualPort(journal, "Probe.UnitA.Pulse");
      ((TextBlock)window.FindName("ModeBanner")).Text = "本地输入探针：仅记录输入意图。PLC 未接入；12.5 为示例值，PLC 接收与执行均未验证。";
      ((TextBlock)window.FindName("JournalTitle")).Text = "本地输入记录：" + journal.Count + "  ·  PLC 接收、扫描周期及执行结果：未测量";
      ((ListBox)window.FindName("Journal")).ItemsSource = journal.Entries.ToArray();
      window.UpdateLayout(); Pump();
      Check(parameter.ActualWidth > 300 && key.ActualHeight >= 78, "actual WPF layout gives both input controls usable bounds");
      if (renderPath != null) Render((FrameworkElement)window.Content, renderPath);
    }
    finally { window.Close(); Pump(); }
    Check(parameterPort.SubscriberCount == 0 && manualPort.SubscriberCount == 0,
      "closing the actual WPF window detaches port subscriptions");
  }
  private static void Render(FrameworkElement root, string path)
  {
    int width = (int)Math.Ceiling(root.ActualWidth), height = (int)Math.Ceiling(root.ActualHeight);
    var drawing = new DrawingVisual();
    using (var context = drawing.RenderOpen())
    {
      context.DrawRectangle(new SolidColorBrush(Color.FromRgb(241, 245, 247)), null, new Rect(0, 0, width, height));
      context.DrawRectangle(new VisualBrush(root) { Stretch = Stretch.Fill }, null, new Rect(0, 0, width, height));
    }
    var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(drawing);
    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
    using (var stream = File.Create(path)) encoder.Save(stream);
    Console.WriteLine("WPF layout image: " + path);
  }
}
