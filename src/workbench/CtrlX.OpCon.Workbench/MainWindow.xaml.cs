using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using IOPath = System.IO.Path;

namespace CtrlX.OpCon.Workbench;

public partial class MainWindow : Window
{
    private readonly WorkbenchPaths _paths;
    private RunnerSnapshot? _snapshot;
    private bool _busy;
    private string _lastOutput = string.Empty;

    public MainWindow(WorkbenchPaths paths)
    {
        _paths = paths;
        InitializeComponent();
        EngineeringRootText.Text = paths.EngineeringRoot;
        PlanPathText.Text = GetPlanPath();
        RenderProgress();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async void RunNext_Click(object sender, RoutedEventArgs e)
    {
        await RunAndRefreshAsync(WorkbenchCommand.RunNext);
    }

    private async void HostStart_Click(object sender, RoutedEventArgs e)
    {
        await RunAndRefreshAsync(WorkbenchCommand.HostStart);
    }

    private async void HostStop_Click(object sender, RoutedEventArgs e)
    {
        await RunAndRefreshAsync(WorkbenchCommand.HostStop);
    }

    private async void CheckProjectPack_Click(object sender, RoutedEventArgs e)
    {
        if (!TryBeginBusy("Checking Project Pack…"))
        {
            return;
        }
        try
        {
            var result = await CommandExecutor.RunAsync(WorkbenchCommandCatalog.Create(WorkbenchCommand.ProjectPackCheck, _paths));
            SetOutput(result.CombinedOutput);
            ProjectPackStateText.Text = result.Succeeded ? "READY / 检查通过" : $"BLOCKED (exit {result.ExitCode})";
            ProjectPackStateText.Foreground = result.Succeeded ? GetBrush("SafeBrush") : GetBrush("ErrorBrush");
            FooterText.Text = $"Project Pack check finished in {result.Duration.TotalSeconds:0.0}s";
        }
        catch (Exception exception)
        {
            ShowFailure("Project Pack check failed", exception);
        }
        finally
        {
            EndBusy();
        }
    }

    private async Task RunAndRefreshAsync(WorkbenchCommand command)
    {
        if (!TryBeginBusy($"Running {command}…"))
        {
            return;
        }
        try
        {
            var result = await CommandExecutor.RunAsync(WorkbenchCommandCatalog.Create(command, _paths));
            SetOutput(result.CombinedOutput);
            FooterText.Text = $"{command} finished with exit {result.ExitCode} in {result.Duration.TotalSeconds:0.0}s";
        }
        catch (Exception exception)
        {
            ShowFailure($"{command} failed", exception);
        }
        finally
        {
            EndBusy();
        }

        await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (!TryBeginBusy("Refreshing offline status…"))
        {
            return;
        }
        try
        {
            var runner = await CommandExecutor.RunAsync(WorkbenchCommandCatalog.Create(WorkbenchCommand.RefreshRunnerStatus, _paths));
            CommandResult? host = null;
            try
            {
                host = await CommandExecutor.RunAsync(WorkbenchCommandCatalog.Create(WorkbenchCommand.HostStatus, _paths));
            }
            catch (Exception exception)
            {
                host = new CommandResult(1, string.Empty, exception.Message, TimeSpan.Zero);
            }

            var runnerText = runner.CombinedOutput;
            var hostText = host.CombinedOutput;
            _snapshot = WorkbenchStatusReader.Read(_paths, runnerText, hostText);
            SetOutput(string.Join(Environment.NewLine + Environment.NewLine,
                new[] { _lastOutput, runnerText, hostText }.Where(value => !string.IsNullOrWhiteSpace(value))));
            RenderSnapshot(_snapshot);
            FooterText.Text = $"Refreshed {_snapshot.RefreshedAt:yyyy-MM-dd HH:mm:ss}";
        }
        catch (Exception exception)
        {
            ShowFailure("Status refresh failed", exception);
            RenderSnapshot(new RunnerSnapshot(
                RunnerStateMapper.Map("FAILED", exception.Message),
                _paths.LatestManifest,
                "UNKNOWN",
                exception.ToString(),
                DateTimeOffset.Now,
                WorkbenchFiles.ReadJsonObject(_paths.LatestManifest, 8 * 1024 * 1024)));
        }
        finally
        {
            EndBusy();
        }
    }

    private void RenderSnapshot(RunnerSnapshot snapshot)
    {
        StateCaptionText.Text = snapshot.Status.Caption;
        StateCodeText.Text = snapshot.Status.State;
        NextActionText.Text = snapshot.Status.NextAction;
        HostStateText.Text = $"Host: {snapshot.HostState}";
        StateIndicator.Fill = snapshot.Status.Kind switch
        {
            WorkflowStatusKind.Done or WorkflowStatusKind.Ready => GetBrush("SafeBrush"),
            WorkflowStatusKind.WaitingForHuman or WorkflowStatusKind.WaitingForAgent or WorkflowStatusKind.DoneOffline => GetBrush("WarnBrush"),
            WorkflowStatusKind.Blocked or WorkflowStatusKind.Failed => GetBrush("ErrorBrush"),
            WorkflowStatusKind.RunningOffline => GetBrush("BlueBrush"),
            _ => Brushes.SlateGray
        };

        ManifestPathText.Text = string.IsNullOrWhiteSpace(snapshot.ManifestPath) ? "No manifest found" : snapshot.ManifestPath;
        var online = snapshot.Manifest?["guardrails"]?["onlineOperationsUsed"]?.ToString() ?? "false";
        var pleStarted = snapshot.Manifest?["guardrails"]?["pleOrMcpStartedByAction"]?.ToString() ?? "false";
        GuardrailText.Text = $"Online operations: {online}  ·  PLE/MCP started by action: {pleStarted}";
        GuardrailText.Foreground = online.Equals("false", StringComparison.OrdinalIgnoreCase)
            ? GetBrush("SafeBrush")
            : GetBrush("ErrorBrush");
    }

    private void RenderProgress()
    {
        PhasePanel.Children.Clear();
        var text = WorkbenchFiles.ReadBoundedText(_paths.Todo, 4 * 1024 * 1024);
        var phases = WorkbenchProgressParser.Parse(text);
        foreach (var phase in phases)
        {
            var row = new Grid { Margin = new Thickness(0, 0, 0, 11) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var indicator = new Ellipse
            {
                Width = 12,
                Height = 12,
                Margin = new Thickness(0, 5, 10, 0),
                VerticalAlignment = VerticalAlignment.Top,
                Fill = phase.Complete ? GetBrush("SafeBrush") : phase.Current ? GetBrush("WarnBrush") : Brushes.LightSlateGray
            };
            var content = new StackPanel();
            content.Children.Add(new TextBlock
            {
                Text = $"{phase.Id}  {phase.Title}",
                FontWeight = phase.Current ? FontWeights.Bold : FontWeights.SemiBold
            });
            if (phase.Current)
            {
                content.Children.Add(new TextBlock
                {
                    Text = "CURRENT / 当前",
                    Foreground = GetBrush("WarnBrush"),
                    FontSize = 11,
                    Margin = new Thickness(0, 2, 0, 0)
                });
            }
            Grid.SetColumn(content, 1);
            row.Children.Add(indicator);
            row.Children.Add(content);
            PhasePanel.Children.Add(row);
        }
    }

    private bool TryBeginBusy(string message)
    {
        if (_busy)
        {
            return false;
        }
        _busy = true;
        SetButtonsEnabled(false);
        FooterText.Text = message;
        return true;
    }

    private void EndBusy()
    {
        _busy = false;
        SetButtonsEnabled(true);
    }

    private void SetButtonsEnabled(bool enabled)
    {
        RefreshButton.IsEnabled = enabled;
        RunNextButton.IsEnabled = enabled;
        HostStartButton.IsEnabled = enabled;
        HostStopButton.IsEnabled = enabled;
        CheckProjectPackButton.IsEnabled = enabled;
    }

    private void SetOutput(string output)
    {
        _lastOutput = output.Trim();
        OutputText.Text = _lastOutput;
        OutputText.ScrollToEnd();
    }

    private void ShowFailure(string title, Exception exception)
    {
        SetOutput(string.Join(Environment.NewLine + Environment.NewLine,
            new[] { _lastOutput, $"{title}: {exception.Message}" }.Where(value => !string.IsNullOrWhiteSpace(value))));
        FooterText.Text = title;
    }

    private void OpenCpStudio_Click(object sender, RoutedEventArgs e)
    {
        if (_paths.CpStudioProject is null || !File.Exists(_paths.CpStudioProject))
        {
            MessageBox.Show("Configured CpStudio project was not found.", Title, MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        OpenWithShell(_paths.CpStudioProject!);
    }

    private void OpenRoot_Click(object sender, RoutedEventArgs e) => OpenWithShell(_paths.EngineeringRoot);

    private void OpenLatestManifest_Click(object sender, RoutedEventArgs e)
    {
        var path = _snapshot?.ManifestPath;
        if (string.IsNullOrWhiteSpace(path))
        {
            path = _paths.LatestManifest;
        }
        SelectFile(path);
    }

    private void OpenPlan_Click(object sender, RoutedEventArgs e) => SelectFile(GetPlanPath());

    private void CopyOutput_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(_lastOutput))
        {
            Clipboard.SetText(_lastOutput);
            FooterText.Text = "Output copied to clipboard.";
        }
    }

    private string GetPlanPath() => IOPath.Combine(_paths.EngineeringRoot, "generated", "engineering-plan.json");

    private static void SelectFile(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            MessageBox.Show("The requested file was not found.", "ctrlX OpCon Engineering Console", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add("/select,");
        info.ArgumentList.Add(path!);
        Process.Start(info);
    }

    private static void OpenWithShell(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private static Brush GetBrush(string key) => (Brush)Application.Current.FindResource(key);
}
