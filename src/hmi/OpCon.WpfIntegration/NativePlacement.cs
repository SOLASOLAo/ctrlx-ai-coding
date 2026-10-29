using System;
using System.Drawing;
using System.Runtime.CompilerServices;
using System.Windows.Forms;
using Bosch.OpCon.HMI.Modulo.Forms;
using FrameworkElement = System.Windows.FrameworkElement;
using WpfPoint = System.Windows.Point;

namespace OpCon.WpfIntegration
{
  internal sealed class NativePlacement : IDisposable
  {
    private sealed class Lease { internal WeakReference Owner; }
    private static readonly ConditionalWeakTable<Control, Lease> Owners = new ConditionalWeakTable<Control, Lease>();
    private readonly Rectangle originalBounds;
    private readonly Control originalParent;
    private readonly bool originalTabStop;
    private readonly Region originalRegion;
    private Region appliedRegion;
    private readonly WpfViewHost owner;
    private bool suppressed;
    private bool pressed;
    internal readonly Control Control;
    internal readonly FrameworkElement Slot;
    internal bool IsSuppressed { get { return suppressed; } }

    internal NativePlacement(WpfViewHost host, Control control, FrameworkElement slot)
    {
      Lease lease;
      if (Owners.TryGetValue(control, out lease) && lease.Owner.IsAlive)
        throw new InvalidOperationException("A native control is already claimed by another WPF host: " + control.Name);
      owner = host; Control = control; Slot = slot;
      originalParent = control.Parent;
      originalTabStop = control.TabStop;
      originalBounds = control.Bounds;
      originalRegion = control.Region == null ? null : control.Region.Clone();
      Owners.Remove(control);
      Owners.Add(control, new Lease { Owner = new WeakReference(host) });
      try
      {
        if (control is Mod_ManualFunctionKey)
        {
          control.MouseDown += MouseDown; control.MouseUp += MouseUp;
          control.MouseCaptureChanged += CaptureChanged; control.LostFocus += LostFocus;
        }
        Suppress();
      }
      catch
      {
        DetachEvents(); Owners.Remove(control);
        if (originalRegion != null) originalRegion.Dispose();
        throw;
      }
    }

    private void DetachEvents()
    {
      Control.MouseDown -= MouseDown; Control.MouseUp -= MouseUp;
      Control.MouseCaptureChanged -= CaptureChanged; Control.LostFocus -= LostFocus;
    }

    private void MouseDown(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed = true; }
    private void MouseUp(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed = false; }
    private void LostFocus(object sender, EventArgs e) { pressed = false; }
    private void CaptureChanged(object sender, EventArgs e)
    {
      if (pressed && !Control.Capture)
      { pressed = false; owner.MoveInputFocusToView(); }
    }

    internal static bool RectangleIsValid(WpfPoint a, WpfPoint b, WpfPoint c, WpfPoint d)
    {
      return !Double.IsNaN(a.X) && !Double.IsInfinity(a.X) &&
        !Double.IsNaN(a.Y) && !Double.IsInfinity(a.Y) &&
        b.X > a.X && c.Y > a.Y &&
        Math.Abs(a.Y - b.Y) < 0.5 && Math.Abs(a.X - c.X) < 0.5 &&
        Math.Abs(d.X - b.X) < 0.5 && Math.Abs(d.Y - c.Y) < 0.5;
    }

    private void SetRegion(Region value)
    {
      Control.Region = value;
      if (appliedRegion != null) appliedRegion.Dispose();
      appliedRegion = value;
    }

    internal void Suppress()
    {
      if (Control.IsDisposed || Control.Parent != originalParent) return;
      // Moving focus uses the native LostFocus path. Never write its request item.
      var editor = Control as Mod_VarIn;
      if (editor != null && (!suppressed || Control.ContainsFocus)) editor.StopEdit(false);
      if (Control.ContainsFocus)
      {
        owner.MoveInputFocusToView();
      }
      if (Control.Capture) Control.Capture = false;
      Control.TabStop = false;
      if (suppressed) return;
      var empty = new Region(); empty.MakeEmpty(); SetRegion(empty);
      suppressed = true;
    }

    internal void Place()
    {
      if (Control.IsDisposed || Control.Parent != owner.Parent)
        throw new InvalidOperationException("Native controls must retain their original SmartForms parent");
      if (!Slot.IsVisible || Slot.ActualWidth < 1 || Slot.ActualHeight < 1)
      { Suppress(); return; }
      var a = Slot.PointToScreen(new WpfPoint(0, 0));
      var b = Slot.PointToScreen(new WpfPoint(Slot.ActualWidth, 0));
      var c = Slot.PointToScreen(new WpfPoint(0, Slot.ActualHeight));
      var d = Slot.PointToScreen(new WpfPoint(Slot.ActualWidth, Slot.ActualHeight));
      if (!RectangleIsValid(a, b, c, d)) throw new InvalidOperationException("Native slots must be axis-aligned rectangles");
      var position = Control.Parent.PointToClient(new Point((int)Math.Round(a.X), (int)Math.Round(a.Y)));
      var rectangle = new Rectangle(position, new Size((int)Math.Round(b.X - a.X), (int)Math.Round(c.Y - a.Y)));
      var viewport = Control.Parent.RectangleToClient(owner.RectangleToScreen(owner.ClientRectangle));
      if (rectangle.Width < 1 || rectangle.Height < 1 || !viewport.Contains(rectangle) ||
          !Control.Parent.ClientRectangle.Contains(rectangle))
        throw new InvalidOperationException("A native slot is clipped outside its HMI viewport");
      bool moved = Control.Bounds != rectangle;
      if (moved) Control.Bounds = rectangle;
      if (suppressed)
      {
        SetRegion(originalRegion == null ? null : originalRegion.Clone());
        Control.TabStop = originalTabStop;
      }
      if (suppressed || moved) Control.BringToFront();
      suppressed = false;
    }

    public void Dispose()
    {
      Lease lease;
      if (!Owners.TryGetValue(Control, out lease) || lease.Owner.Target != owner) return;
      try
      {
        Suppress();
        if (!Control.IsDisposed && Control.Parent == originalParent)
        {
          Control.Bounds = originalBounds;
          Control.TabStop = originalTabStop;
          SetRegion(originalRegion == null ? null : originalRegion.Clone());
        }
      }
      finally
      {
        DetachEvents();
        Owners.Remove(Control);
        if (originalRegion != null) originalRegion.Dispose();
        // Control owns the restored region until it is replaced or disposed.
        appliedRegion = null;
      }
    }
  }
}
