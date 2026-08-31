using System.Text.Json;
using System.Windows;

namespace CtrlX.OpCon.Workbench;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            var options = WorkbenchOptions.Parse(e.Args);
            var paths = WorkbenchRoot.Validate(options.EngineeringRoot);

            if (options.SmokeTest)
            {
                var result = WorkbenchSmokeTest.Run(paths);
                Console.WriteLine(JsonSerializer.Serialize(result));
                Shutdown(result.Ready ? 0 : 1);
                return;
            }

            var window = new MainWindow(paths);
            MainWindow = window;
            window.Show();
        }
        catch (Exception exception)
        {
            if (e.Args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase))
            {
                Console.Error.WriteLine(exception.Message);
                Shutdown(2);
                return;
            }

            MessageBox.Show(
                exception.Message,
                "ctrlX OpCon Engineering Console",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(2);
        }
    }
}
