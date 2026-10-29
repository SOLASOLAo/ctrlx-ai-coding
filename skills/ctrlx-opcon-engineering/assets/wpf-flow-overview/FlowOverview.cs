using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

internal static class FlowOverview
{
  private static void Pump(int milliseconds)
  {
    var frame = new DispatcherFrame();
    var end = new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(milliseconds)};
    end.Tick += (sender, e) => {end.Stop(); frame.Continue=false;};
    end.Start(); Dispatcher.PushFrame(frame);
  }

  [STAThread]
  private static int Main(string[] args)
  {
    try {
      var application = new Application();
      Window window;
      using (var input = File.OpenRead(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "FlowOverview.xaml")))
        window = (Window)XamlReader.Load(input);
      var view = (FrameworkElement)window.FindName("View");
      if (args.Length == 2 && args[0] == "--render") {
        // Render the real WPF layout offscreen; it leaves engineering windows alone.
        view.Resources = window.Resources;
        window.Content = null;
        view.Measure(new Size(944, 572)); view.Arrange(new Rect(0, 0, 944, 572)); view.UpdateLayout();
        var bitmap = new RenderTargetBitmap(944, 572, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(view);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var output = File.Create(Path.GetFullPath(args[1]))) encoder.Save(output);
        return 0;
      }
      bool selfTest = args.Length == 1 && args[0] == "--self-test";
      bool embedded = args.Length == 1 && args[0] == "--embedded";
      if (args.Length != 0 && !selfTest && !embedded) throw new ArgumentException("Usage: ST60.FlowOverview.exe [--render output.png | --self-test | --embedded]");
      if (embedded) {
        window.WindowStyle=WindowStyle.None; window.ResizeMode=ResizeMode.NoResize;
        window.Width=944; window.Height=572;
      }
      var motion = (TranslateTransform)window.FindName("MarkerMotion");
      var progress = (ProgressBar)window.FindName("StageProgress");
      var playback = (TextBlock)window.FindName("PlaybackState");
      var current = (TextBlock)window.FindName("CurrentStage");
      var stages = new Border[3]; var labels = new TextBlock[3];
      for (int i=0; i<3; i++) {
        stages[i]=(Border)window.FindName("Stage" + i);
        labels[i]=(TextBlock)window.FindName("Status" + i);
      }
      string[] names = {"上料等待", "工件处理", "结果确认"};
      int stage = 0;
      var timer = new DispatcherTimer {Interval=TimeSpan.FromSeconds(2.4)};
      Action advance = () => {
        stage = (stage + 1) % 3;
        current.Text = names[stage]; progress.Value = (stage + 1) * 100.0 / 3;
        for (int i=0; i<3; i++) {
          stages[i].BorderBrush = new SolidColorBrush(i==stage ? Color.FromRgb(24,106,240) : Color.FromRgb(223,231,240));
          labels[i].Text = i==stage ? "演示进行中" : "等待演示";
        }
        motion.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(stage * 205, TimeSpan.FromSeconds(0.65)) {EasingFunction=new CubicEase {EasingMode=EasingMode.EaseInOut}});
      };
      timer.Tick += (sender, e) => advance();
      ((Button)window.FindName("PlayButton")).Click += (sender, e) => {
        if (!timer.IsEnabled) advance();
        timer.Start(); playback.Text="演示播放中 · 无 PLC 通信";
      };
      ((Button)window.FindName("PauseButton")).Click += (sender, e) => {timer.Stop(); playback.Text="演示已暂停";};
      window.Closed += (sender, e) => timer.Stop();
      if (selfTest) {
        // WPF's animation clock needs a presentation source. Keep this test
        // window outside the desktop and never activate it or add a taskbar tab.
        window.WindowStartupLocation=WindowStartupLocation.Manual;
        window.Left=-10000; window.Top=-10000;
        window.ShowActivated=false; window.ShowInTaskbar=false;
        window.Show();
        Pump(100);
        ((Button)window.FindName("PlayButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Pump(900);
        if (current.Text != names[1] || Math.Abs(motion.X - 205) > 0.1 || !timer.IsEnabled)
          throw new InvalidOperationException("Play/animation incomplete: stage=" + current.Text + ", position=" + motion.X + ", timer=" + timer.IsEnabled);
        ((Button)window.FindName("PauseButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Pump(2600);
        if (stage != 1 || timer.IsEnabled) throw new InvalidOperationException("Pause did not stop demo progression.");
        window.Close();
        return 0;
      }
      application.Run(window);
      return 0;
    } catch (Exception error) {
      File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "last-error.txt"), error.ToString());
      return 1;
    }
  }
}
