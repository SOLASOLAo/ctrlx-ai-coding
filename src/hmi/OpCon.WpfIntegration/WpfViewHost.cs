using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Forms.Integration;
using System.Windows.Markup;
using Bosch.OpCon.HMI.Modulo.Forms;
using Bosch.OpCon.HMI.Modulo.Shared;
using VisiWinNET.LanguageSwitching;
using Forms = System.Windows.Forms;

namespace OpCon.WpfIntegration
{
  /// <summary>
  /// WPF presentation inside an existing SmartForms page. Native operation
  /// controls remain siblings; this host has no command or PLC-write method.
  /// </summary>
  [ToolboxItem(true)]
  public sealed class WpfViewHost : Forms.UserControl
  {
    private readonly ElementHost element = new ElementHost { Dock = Forms.DockStyle.Fill };
    private readonly Forms.Timer timer = new Forms.Timer { Interval = 250 };
    private readonly List<NativePlacement> placements = new List<NativePlacement>();
    private readonly Dictionary<TextBlock, LocalizedText> texts = new Dictionary<TextBlock, LocalizedText>();
    private readonly List<TextBlock> values = new List<TextBlock>();
    private FrameworkElement view;
    private NativeReadSet reader;
    private OpconUnit mappedOwner;
    private bool disposed, mappingReady;
    private int heartbeatTimeoutMs = 2000;
    private string layoutFile = "", itemPrefix = "", heartbeatItem = "";

    [DefaultValue("")]
    public string LayoutFile
    {
      get { return layoutFile; }
      set { if (view != null) throw new InvalidOperationException("Recreate the page to change its layout"); layoutFile = value ?? ""; }
    }
    [DefaultValue("")]
    public string ItemPrefix
    {
      get { return itemPrefix; }
      set { if (mappingReady) throw new InvalidOperationException("Recreate the page to change its instance"); itemPrefix = value ?? ""; }
    }
    [DefaultValue("")]
    public string HeartbeatItem
    {
      get { return heartbeatItem; }
      set { if (mappingReady) throw new InvalidOperationException("Recreate the page to change its heartbeat binding"); heartbeatItem = value ?? ""; }
    }
    [DefaultValue(2000)]
    public int HeartbeatTimeoutMs
    {
      get { return heartbeatTimeoutMs; }
      set { if (value < 500 || value > 30000) throw new ArgumentOutOfRangeException("value"); heartbeatTimeoutMs = value; }
    }
    [Browsable(false)] public bool IsFresh { get { return reader != null && reader.IsFresh; } }
    [Browsable(false)] public string LastError { get; private set; }
    [Browsable(false)] public int ActiveItemCount { get { return reader == null ? 0 : reader.Count; } }

    public WpfViewHost()
    {
      LayoutFile = ItemPrefix = HeartbeatItem = "";
      AutoScaleMode = Forms.AutoScaleMode.None;
      Size = new System.Drawing.Size(944, 572);
      Controls.Add(element);
      timer.Tick += Tick;
    }

    private bool IsDesigning { get { return DesignMode || LicenseManager.UsageMode == LicenseUsageMode.Designtime; } }

    protected override void OnCreateControl()
    {
      base.OnCreateControl();
      if (IsDesigning) return;
      try { LoadView(); UpdateActivity(); }
      catch (Exception error) { Fail(error); }
    }

    private void LoadView()
    {
      if (view != null) return;
      if (String.IsNullOrWhiteSpace(LayoutFile) || Path.IsPathRooted(LayoutFile))
        throw new ArgumentException("LayoutFile must be relative to the HMI application directory");
      string root = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory);
      string file = Path.GetFullPath(Path.Combine(root, LayoutFile));
      if (!file.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
          !String.Equals(Path.GetExtension(file), ".xaml", StringComparison.OrdinalIgnoreCase) ||
          new FileInfo(file).Length > 262144)
        throw new ArgumentException("Use an owned XAML layout of at most 256 KiB inside the HMI directory");
      // Layouts are trusted component resources, not a sandbox for untrusted XAML.
      using (var stream = File.OpenRead(file)) view = XamlReader.Load(stream) as FrameworkElement;
      if (view == null) throw new InvalidDataException("Layout root must be a WPF FrameworkElement");
      view.Focusable = true;
      foreach (var value in Elements(view).OfType<TextBlock>().Where(x => !String.IsNullOrEmpty(NativeValue.GetPath(x))))
        value.Text = "—";
      element.Child = view;
      view.LayoutUpdated += LayoutUpdated;
    }

    private static IEnumerable<FrameworkElement> Elements(FrameworkElement root)
    {
      var pending = new Stack<FrameworkElement>(); pending.Push(root);
      int count = 0;
      while (pending.Count > 0)
      {
        var current = pending.Pop();
        if (++count > 4096) throw new InvalidDataException("Layout has more than 4096 elements");
        yield return current;
        foreach (object child in LogicalTreeHelper.GetChildren(current))
        { var item = child as FrameworkElement; if (item != null) pending.Push(item); }
      }
    }

    private bool InitializeMapping()
    {
      var page = Parent as SmartControl;
      if (page == null) throw new InvalidOperationException("WpfViewHost must be a direct child of the owning native SmartControl");
      if (mappingReady)
      {
        if (!Object.ReferenceEquals(page.OwnerUnit, mappedOwner))
          throw new InvalidOperationException("Native page ownership changed; recreate its configured WPF host");
        return true;
      }
      if (page.OwnerUnit == null) return false;
      var slots = Elements(view).Where(x => !String.IsNullOrEmpty(NativeSlot.GetControlName(x))).ToArray();
      var display = Elements(view).OfType<TextBlock>().Where(x => !String.IsNullOrEmpty(NativeValue.GetPath(x))).ToArray();
      var labels = Elements(view).OfType<TextBlock>().Where(x => !String.IsNullOrEmpty(NativeText.GetKey(x))).ToArray();
      if (slots.Length > 64 || labels.Length > 64 || slots.Select(NativeSlot.GetControlName).Distinct(StringComparer.Ordinal).Count() != slots.Length)
        throw new InvalidDataException("Use at most 64 unique native slots and 64 localized labels");
      if (display.Intersect(labels).Any()) throw new InvalidDataException("A label cannot be both NativeValue and NativeText");
      var selected = new List<KeyValuePair<FrameworkElement, Forms.Control>>();
      foreach (var slot in slots)
      {
        string name = NativeSlot.GetControlName(slot);
        var matching = page.Controls.Cast<Forms.Control>().Where(c => c.Name == name).ToArray();
        if (matching.Length != 1) throw new InvalidDataException("Native slot needs one direct sibling control: " + name);
        var control = matching[0];
        var key = control as Mod_ManualFunctionKey;
        var input = control as Mod_VarIn;
        if (key == null && input == null && !(control is Mod_VarOut))
          throw new InvalidDataException("Unsupported native operation control: " + name);
        if ((key != null && (!key.UseTokenHandling || String.IsNullOrWhiteSpace(key.ManualFunctionName))) ||
            (input != null && !input.UseTokenHandling))
          throw new InvalidDataException("Native operation controls require their normal token handling and manual function binding");
        if (key != null && key.GlobalHotKey)
          throw new InvalidDataException("Keep global/hardware shortcuts outside presentation slots; use focused native key input here");
        selected.Add(new KeyValuePair<FrameworkElement, Forms.Control>(slot, control));
      }
      var readSet = new NativeReadSet(ItemPrefix, HeartbeatItem, display.Select(NativeValue.GetPath));
      try
      {
        foreach (var entry in selected) placements.Add(new NativePlacement(this, entry.Value, entry.Key));
        foreach (var label in labels)
          texts.Add(label, new LocalizedText { TextGroup = NativeText.GetGroup(label), Text = NativeText.GetKey(label) });
        values.AddRange(display);
        reader = readSet;
        mappedOwner = page.OwnerUnit;
        mappingReady = true;
        return true;
      }
      catch
      {
        // Always attempt every presentation cleanup, even if the native item
        // system reports a detach/disposal fault during failed initialization.
        try { readSet.Dispose(); }
        finally { ClearMapping(); }
        throw;
      }
    }

    private void Tick(object sender, EventArgs args)
    {
      if (disposed || !Visible || view == null || !view.IsLoaded) return;
      try
      {
        if (!InitializeMapping()) return;
        reader.Attach(); reader.Poll(HeartbeatTimeoutMs);
        foreach (var label in texts) label.Key.Text = String.IsNullOrEmpty(label.Value.DisplayText) ?
          "[" + NativeText.GetKey(label.Key) + "]" : label.Value.DisplayText;
        foreach (var value in values) value.Text = reader.Display(NativeValue.GetPath(value), NativeValue.GetFormat(value));
        PlaceControls(); LastError = null;
      }
      catch (Exception error) { Fail(error); }
    }

    private void LayoutUpdated(object sender, EventArgs args)
    {
      if (disposed || !mappingReady) return;
      try { PlaceControls(); }
      catch (Exception error) { Fail(error); }
    }

    private void PlaceControls()
    {
      var rectangles = new List<System.Drawing.Rectangle>();
      foreach (var placement in placements)
      {
        if (Visible && IsFresh) placement.Place(); else placement.Suppress();
        if (placement.IsSuppressed) continue;
        var rectangle = placement.Control.Bounds;
        if (rectangles.Any(other => other.IntersectsWith(rectangle)))
          throw new InvalidOperationException("Native input slots cannot overlap");
        rectangles.Add(rectangle);
      }
    }

    private void Fail(Exception error)
    {
      LastError = error.GetType().Name + ": " + error.Message;
      if (reader != null) reader.Invalidate();
      foreach (var value in values) value.Text = "—";
      foreach (var placement in placements)
      { try { placement.Suppress(); } catch (Exception releaseError) { LastError += "; " + releaseError.GetType().Name; } }
    }

    internal void MoveInputFocusToView() { if (!element.IsDisposed) element.Focus(); }

    private void UpdateActivity()
    {
      if (Visible && view != null) { timer.Start(); return; }
      timer.Stop();
      foreach (var placement in placements) placement.Suppress();
      if (reader != null) reader.Detach();
      foreach (var value in values) value.Text = "—";
    }

    protected override void OnVisibleChanged(EventArgs e)
    {
      base.OnVisibleChanged(e);
      if (!IsDesigning && !disposed)
      { try { UpdateActivity(); } catch (Exception error) { Fail(error); } }
    }

    protected override void OnParentChanged(EventArgs e)
    {
      if (mappingReady) ClearMapping();
      base.OnParentChanged(e);
    }

    private void ClearMapping()
    {
      Exception firstError = null;
      foreach (var placement in placements)
      { try { placement.Dispose(); } catch (Exception error) { if (firstError == null) firstError = error; } }
      placements.Clear();
      foreach (var text in texts.Values)
      { try { text.Dispose(); } catch (Exception error) { if (firstError == null) firstError = error; } }
      texts.Clear(); values.Clear();
      if (reader != null)
      {
        try { reader.Dispose(); } catch (Exception error) { if (firstError == null) firstError = error; }
        reader = null;
      }
      mappingReady = false;
      mappedOwner = null;
      if (firstError != null) throw new InvalidOperationException("Native presentation cleanup failed", firstError);
    }

    protected override void Dispose(bool disposing)
    {
      try
      {
        if (disposing && !disposed)
        {
          disposed = true; timer.Stop(); timer.Tick -= Tick; timer.Dispose();
          if (view != null) view.LayoutUpdated -= LayoutUpdated;
          try { ClearMapping(); }
          catch (Exception error) { LastError = error.Message; }
          try { element.Child = null; element.Dispose(); }
          finally { view = null; }
        }
      }
      finally { base.Dispose(disposing); }
    }
  }
}
