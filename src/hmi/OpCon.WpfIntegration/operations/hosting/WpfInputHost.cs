using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Forms.Integration;
using System.Windows.Markup;
using Forms = System.Windows.Forms;

namespace OpCon.WpfIntegration.Operations.Hosting
{
  // In-process view host only. No vendor operation API, driver, or connection is started.
  // Its visible children are WPF. Native SmartForms can construct this WinForms boundary.
  public sealed class WpfInputHost : Forms.UserControl
  {
    private readonly ElementHost element = new ElementHost { Dock = Forms.DockStyle.Fill };
    private readonly ContentControl inputGate = new ContentControl { IsEnabled = false };
    private FrameworkElement view;
    private Forms.Form owner;
    private string layoutFile = "";
    private bool active, disposed;

    [DefaultValue("")]
    public string LayoutFile
    {
      get { return layoutFile; }
      set {
        if (view != null) throw new InvalidOperationException("Recreate the view to change its layout.");
        layoutFile = value ?? "";
      }
    }
    [Browsable(false)] public FrameworkElement View { get { return view; } }
    [Browsable(false)] public string LastError { get; private set; }
    [Browsable(false)] public bool InputActive { get { return inputGate.IsEnabled; } }

    public WpfInputHost()
    {
      AutoScaleMode = Forms.AutoScaleMode.None;
      Size = new System.Drawing.Size(944, 572);
      element.Child = inputGate;
      Controls.Add(element);
    }
    private bool IsDesigning
    { get { return DesignMode || LicenseManager.UsageMode == LicenseUsageMode.Designtime; } }

    protected override void OnCreateControl()
    {
      base.OnCreateControl();
      if (disposed || IsDesigning) return;
      try { LoadView(); AttachOwner(); UpdateActivity("host created"); }
      catch (Exception error) {
        LastError = error.GetType().Name + ": " + error.Message;
        Suspend("layout unavailable");
      }
    }
    private void LoadView()
    {
      if (view != null) return;
      if (String.IsNullOrWhiteSpace(LayoutFile) || Path.IsPathRooted(LayoutFile))
        throw new ArgumentException("LayoutFile must be a relative owned XAML path.");
      string root = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
      string file = Path.GetFullPath(Path.Combine(root, LayoutFile));
      if (!file.StartsWith(root, StringComparison.OrdinalIgnoreCase) ||
          !String.Equals(Path.GetExtension(file), ".xaml", StringComparison.OrdinalIgnoreCase) ||
          new FileInfo(file).Length > 262144)
        throw new ArgumentException("Use an owned XAML of at most 256 KiB inside the application directory.");
      // Trusted component resources only. XAML is executable object construction, not a sandbox.
      FrameworkElement loaded;
      using (var stream = File.OpenRead(file))
        loaded = XamlReader.Load(stream, new ParserContext { BaseUri = new Uri(file) }) as FrameworkElement;
      if (loaded == null || loaded is Window) throw new InvalidDataException("The embedded root must be a non-Window FrameworkElement.");
      inputGate.Content = loaded;
      view = loaded;
      LastError = null;
    }
    private void AttachOwner()
    {
      var current = FindForm();
      if (Object.ReferenceEquals(owner, current)) return;
      Suspend("host owner changed");
      DetachOwner();
      owner = current;
      if (owner == null) return;
      owner.Activated += Activated;
      owner.Deactivate += Deactivated;
      owner.FormClosing += Closing;
      active = Object.ReferenceEquals(Forms.Form.ActiveForm, owner) || owner.ContainsFocus;
    }
    private void DetachOwner()
    {
      if (owner != null) {
        owner.Activated -= Activated;
        owner.Deactivate -= Deactivated;
        owner.FormClosing -= Closing;
      }
      owner = null; active = false;
    }
    private void Activated(object sender, EventArgs e)
    { active = true; UpdateActivity("host activated"); }
    private void Deactivated(object sender, EventArgs e)
    { active = false; Suspend("WinForms window deactivated"); }
    private void Closing(object sender, Forms.FormClosingEventArgs e)
    {
      Suspend("WinForms window closing");
      // Other handlers may cancel FormClosing. Reevaluate after they have run;
      // recovery only opens the local gate and never creates a new input.
      var closingOwner = owner;
      if (closingOwner != null && closingOwner.IsHandleCreated)
        closingOwner.BeginInvoke((Action)(() => {
          if (!disposed && Object.ReferenceEquals(owner, closingOwner) && !closingOwner.IsDisposed)
            UpdateActivity("close cancelled");
        }));
    }
    private static IEnumerable<FrameworkElement> Elements(FrameworkElement root)
    {
      if (root == null) yield break;
      var pending = new Stack<FrameworkElement>();
      pending.Push(root);
      while (pending.Count != 0) {
        var current = pending.Pop();
        yield return current;
        foreach (object child in LogicalTreeHelper.GetChildren(current)) {
          var frameworkChild = child as FrameworkElement;
          if (frameworkChild != null) pending.Push(frameworkChild);
        }
      }
    }
    private void Suspend(string reason)
    {
      if (inputGate == null) return; // WinForms base construction may raise virtual events.
      // Disable a separate ancestor, preserving all caller bindings/Enabled values.
      inputGate.IsEnabled = false;
      foreach (var control in Elements(view)) {
        var parameter = control as WpfParameterBox;
        var manual = control as WpfManualKey;
        if (parameter != null) parameter.CancelInput(reason);
        if (manual != null) manual.CancelInput(reason);
      }
    }
    private void UpdateActivity(string reason)
    {
      if (disposed || owner == null || !active || !Visible || !Enabled || view == null)
        Suspend(reason);
      else
        inputGate.IsEnabled = true;
    }
    protected override void OnVisibleChanged(EventArgs e)
    {
      base.OnVisibleChanged(e);
      if (disposed || IsDesigning) return;
      AttachOwner(); UpdateActivity("host visibility changed");
    }
    protected override void OnEnabledChanged(EventArgs e)
    {
      base.OnEnabledChanged(e);
      if (!disposed) UpdateActivity("host enabled state changed");
    }
    protected override void OnParentChanged(EventArgs e)
    {
      Suspend("host parent changed");
      base.OnParentChanged(e);
      if (!disposed && !IsDesigning) { AttachOwner(); UpdateActivity("host reparented"); }
    }
    protected override void Dispose(bool disposing)
    {
      try {
        if (disposing && !disposed) {
          disposed = true;
          try { Suspend("host disposed"); }
          finally {
            DetachOwner();
            inputGate.Content = null; view = null;
            element.Child = null; element.Dispose();
          }
        }
      }
      finally { base.Dispose(disposing); }
    }
  }
}
