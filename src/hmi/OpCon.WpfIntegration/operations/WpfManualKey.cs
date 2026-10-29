using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace OpCon.WpfIntegration.Operations
{
  /// <summary>WPF press/release input. An adapter, not Click, owns native operation semantics.</summary>
  public class WpfManualKey : ContentControl
  {
    public static readonly DependencyProperty OperationProperty = DependencyProperty.Register(
      "Operation", typeof(IManualOperation), typeof(WpfManualKey), new PropertyMetadata(null, OperationChanged));
    private static readonly DependencyPropertyKey IsPressedPropertyKey = DependencyProperty.RegisterReadOnly(
      "IsPressed", typeof(bool), typeof(WpfManualKey), new PropertyMetadata(false));
    private static readonly DependencyPropertyKey FeedbackPropertyKey = DependencyProperty.RegisterReadOnly(
      "Feedback", typeof(string), typeof(WpfManualKey), new PropertyMetadata("No operation adapter."));
    public static readonly DependencyProperty IsPressedProperty = IsPressedPropertyKey.DependencyProperty;
    public static readonly DependencyProperty FeedbackProperty = FeedbackPropertyKey.DependencyProperty;
    private readonly ManualInputSession session = new ManualInputSession();
    private Window window;
    private TouchDevice touch;
    private Key heldKey;
    private bool mouse, finishing, acquiring;
    public IManualOperation Operation { get { return (IManualOperation)GetValue(OperationProperty); } set { SetValue(OperationProperty, value); } }
    public bool IsPressed { get { return (bool)GetValue(IsPressedProperty); } }
    public string Feedback { get { return (string)GetValue(FeedbackProperty); } }
    protected override bool IsEnabledCore
    { get { return base.IsEnabledCore && session != null && (session.CanStart || session.IsPressed); } }

    static WpfManualKey()
    {
      DefaultStyleKeyProperty.OverrideMetadata(typeof(WpfManualKey), new FrameworkPropertyMetadata(typeof(WpfManualKey)));
      FocusableProperty.OverrideMetadata(typeof(WpfManualKey), new FrameworkPropertyMetadata(true));
    }
    public WpfManualKey()
    {
      session.Changed += (s, e) => Refresh();
      Loaded += (s, e) => {
        window = Window.GetWindow(this);
        if (window != null) window.Deactivated += WindowDeactivated;
        session.Bind(Operation);
      };
      Unloaded += (s, e) => {
        Finish("view unloaded"); session.Bind(null);
        if (window != null) window.Deactivated -= WindowDeactivated;
        window = null;
      };
      IsVisibleChanged += (s, e) => { if (!IsVisible) Finish("view hidden"); };
      IsEnabledChanged += (s, e) => { if (!IsEnabled) Finish("control disabled"); };
    }
    private static void OperationChanged(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
      var control = (WpfManualKey)target;
      control.Finish("binding changed");
      control.session.Bind(control.IsLoaded ? (IManualOperation)e.NewValue : null);
    }
    private void WindowDeactivated(object sender, EventArgs e) { Finish("window deactivated"); }
    // ElementHost must forward its WinForms owner's lifecycle, which has no WPF Window.
    public void CancelInput(string reason)
    { VerifyAccess(); Finish(String.IsNullOrWhiteSpace(reason) ? "host suspended" : reason); }
    private void Refresh()
    {
      SetValue(IsPressedPropertyKey, session.IsPressed);
      SetValue(FeedbackPropertyKey, session.FeedbackFor(session.State));
      CoerceValue(IsEnabledProperty);
      if (!session.IsPressed) DropCapture();
    }
    private void DropCapture()
    {
      if (finishing || acquiring) return;
      finishing = true;
      var capturedTouch = touch; touch = null; mouse = false; heldKey = Key.None;
      if (IsMouseCaptured) ReleaseMouseCapture();
      if (capturedTouch != null && capturedTouch.Captured == this) ReleaseTouchCapture(capturedTouch);
      finishing = false;
    }
    private void Finish(string reason)
    { if (finishing) return; session.Cancel(reason); DropCapture(); }
    private bool MayStart()
    { return IsLoaded && IsVisible && IsEnabled && !session.IsPressed && session.CanStart; }
    private bool BeginInput()
    {
      acquiring = true;
      try { return session.Begin(); }
      finally { acquiring = false; if (!session.IsPressed) DropCapture(); }
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
      base.OnMouseLeftButtonDown(e); e.Handled = true;
      if (e.StylusDevice != null || !MayStart() || !Focus()) return;
      if (!CaptureMouse()) return;
      mouse = true; BeginInput();
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    { base.OnMouseLeftButtonUp(e); if (mouse) { e.Handled = true; Finish("mouse released"); } }
    protected override void OnMouseMove(MouseEventArgs e)
    {
      base.OnMouseMove(e);
      if (mouse && (e.LeftButton != MouseButtonState.Pressed || !Inside(e.GetPosition(this)))) Finish("mouse left input area");
    }
    protected override void OnLostMouseCapture(MouseEventArgs e)
    { base.OnLostMouseCapture(e); if (mouse && !IsMouseCaptured) Finish("mouse capture lost"); }
    protected override void OnTouchDown(TouchEventArgs e)
    {
      base.OnTouchDown(e); e.Handled = true;
      if (!MayStart() || !Focus() || !CaptureTouch(e.TouchDevice)) return;
      touch = e.TouchDevice; BeginInput();
    }
    protected override void OnTouchUp(TouchEventArgs e)
    { base.OnTouchUp(e); e.Handled = true; if (touch == e.TouchDevice) Finish("touch released"); }
    protected override void OnTouchMove(TouchEventArgs e)
    { base.OnTouchMove(e); if (touch == e.TouchDevice && !Inside(e.GetTouchPoint(this).Position)) Finish("touch left input area"); }
    protected override void OnLostTouchCapture(TouchEventArgs e)
    { base.OnLostTouchCapture(e); if (touch == e.TouchDevice) Finish("touch capture lost"); }
    protected override void OnKeyDown(KeyEventArgs e)
    {
      base.OnKeyDown(e);
      if (e.Key == Key.Escape) { e.Handled = true; Finish("escape"); return; }
      if (e.Key != Key.Space && e.Key != Key.Enter) return;
      e.Handled = true;
      if (e.IsRepeat || !IsKeyboardFocused || !MayStart()) return;
      heldKey = e.Key; if (!BeginInput()) heldKey = Key.None;
    }
    protected override void OnKeyUp(KeyEventArgs e)
    { base.OnKeyUp(e); if (heldKey != Key.None && e.Key == heldKey) { e.Handled = true; Finish("key released"); } }
    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e)
    { base.OnLostKeyboardFocus(e); if (!IsKeyboardFocusWithin) Finish("keyboard focus lost"); }
    private bool Inside(Point point)
    { return point.X >= 0 && point.Y >= 0 && point.X < ActualWidth && point.Y < ActualHeight; }
  }
}
