using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace OpCon.WpfIntegration.Operations
{
  [TemplatePart(Name = "PART_Editor", Type = typeof(TextBox))]
  [TemplatePart(Name = "PART_Apply", Type = typeof(Button))]
  [TemplatePart(Name = "PART_Cancel", Type = typeof(Button))]
  public class WpfParameterBox : Control
  {
    public static readonly DependencyProperty OperationProperty = DependencyProperty.Register(
      "Operation", typeof(IParameterOperation), typeof(WpfParameterBox), new PropertyMetadata(null, OperationChanged));
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
      "Label", typeof(string), typeof(WpfParameterBox), new PropertyMetadata(""));
    private static readonly DependencyPropertyKey ObservedValuePropertyKey = DependencyProperty.RegisterReadOnly(
      "ObservedValue", typeof(string), typeof(WpfParameterBox), new PropertyMetadata("—"));
    private static readonly DependencyPropertyKey FeedbackPropertyKey = DependencyProperty.RegisterReadOnly(
      "Feedback", typeof(string), typeof(WpfParameterBox), new PropertyMetadata("No operation adapter."));
    private static readonly DependencyPropertyKey UnitPropertyKey = DependencyProperty.RegisterReadOnly(
      "Unit", typeof(string), typeof(WpfParameterBox), new PropertyMetadata(""));
    public static readonly DependencyProperty ObservedValueProperty = ObservedValuePropertyKey.DependencyProperty;
    public static readonly DependencyProperty FeedbackProperty = FeedbackPropertyKey.DependencyProperty;
    public static readonly DependencyProperty UnitProperty = UnitPropertyKey.DependencyProperty;
    private readonly ParameterInputSession session = new ParameterInputSession();
    private TextBox editor;
    private Button apply, cancel;
    private Window window;
    public IParameterOperation Operation { get { return (IParameterOperation)GetValue(OperationProperty); } set { SetValue(OperationProperty, value); } }
    public string Label { get { return (string)GetValue(LabelProperty); } set { SetValue(LabelProperty, value); } }
    public string ObservedValue { get { return (string)GetValue(ObservedValueProperty); } }
    public string Feedback { get { return (string)GetValue(FeedbackProperty); } }
    public string Unit { get { return (string)GetValue(UnitProperty); } }
    private CultureInfo Culture { get { return Language.GetSpecificCulture(); } }

    static WpfParameterBox()
    { DefaultStyleKeyProperty.OverrideMetadata(typeof(WpfParameterBox), new FrameworkPropertyMetadata(typeof(WpfParameterBox))); }
    public WpfParameterBox()
    {
      session.Changed += (s, e) => Refresh();
      Loaded += (s, e) => {
        window = Window.GetWindow(this);
        if (window != null) window.Deactivated += WindowDeactivated;
        session.Bind(Operation);
      };
      Unloaded += (s, e) => {
        session.Bind(null);
        if (window != null) window.Deactivated -= WindowDeactivated;
        window = null;
      };
      IsVisibleChanged += (s, e) => { if (!IsVisible) session.Cancel("view hidden"); };
      IsEnabledChanged += (s, e) => { if (!IsEnabled) session.Cancel("control disabled"); Refresh(); };
    }
    private static void OperationChanged(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
      var control = (WpfParameterBox)target;
      control.session.Bind(control.IsLoaded ? (IParameterOperation)e.NewValue : null);
    }
    private void WindowDeactivated(object sender, EventArgs e) { session.Cancel("window deactivated"); }
    // WinForms/ElementHost has no WPF Window. Its owner must forward loss of activity.
    // This can only cancel our input; it cannot grant permission or submit a value.
    public void CancelInput(string reason)
    { VerifyAccess(); session.Cancel(String.IsNullOrWhiteSpace(reason) ? "host suspended" : reason); }
    public override void OnApplyTemplate()
    {
      session.Cancel("template changed");
      if (editor != null) {
        editor.PreviewMouseLeftButtonDown -= EditorMouseDown;
        editor.PreviewKeyDown -= EditorKeyDown;
      }
      if (apply != null) apply.Click -= ApplyClicked;
      if (cancel != null) cancel.Click -= CancelClicked;
      base.OnApplyTemplate();
      editor = GetTemplateChild("PART_Editor") as TextBox;
      apply = GetTemplateChild("PART_Apply") as Button; cancel = GetTemplateChild("PART_Cancel") as Button;
      if (editor != null) {
        editor.PreviewMouseLeftButtonDown += EditorMouseDown;
        editor.PreviewKeyDown += EditorKeyDown;
      }
      if (apply != null) apply.Click += ApplyClicked;
      if (cancel != null) cancel.Click += CancelClicked;
      Refresh();
    }
    private void EditorMouseDown(object sender, MouseButtonEventArgs e) { BeginEdit(); }
    private void BeginEdit()
    { if (IsLoaded && IsVisible && IsEnabled && editor != null && apply != null && cancel != null && !session.IsEditing) session.Begin(); }
    private void EditorKeyDown(object sender, KeyEventArgs e)
    {
      if (e.Key == Key.Escape) { e.Handled = true; session.Cancel("escape"); return; }
      if (e.Key == Key.Enter) {
        e.Handled = true;
        if (e.IsRepeat) return;
        if (session.IsEditing) session.Submit(editor.Text, Culture); else BeginEdit();
        return;
      }
      // Focus can be restored by ElementHost after activation/reopening. Focus alone
      // must not begin a native edit. Start only on explicit input, ignoring modifiers.
      if (e.Key != Key.Tab && e.Key != Key.LeftShift && e.Key != Key.RightShift &&
          e.Key != Key.LeftCtrl && e.Key != Key.RightCtrl && e.Key != Key.LeftAlt && e.Key != Key.RightAlt)
        BeginEdit();
    }
    private void ApplyClicked(object sender, RoutedEventArgs e)
    { if (editor != null && IsLoaded && IsVisible && IsEnabled) session.Submit(editor.Text, Culture); }
    private void CancelClicked(object sender, RoutedEventArgs e) { session.Cancel("cancel button"); }
    protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs e)
    { base.OnLostKeyboardFocus(e); if (!IsKeyboardFocusWithin) session.Cancel("keyboard focus left editor"); }
    private void Refresh()
    {
      var state = session.State;
      string value = state != null && state.Value.HasValue ? state.Value.Value.ToString("G", Culture) : "—";
      SetValue(ObservedValuePropertyKey, value); SetValue(UnitPropertyKey, state == null ? "" : state.Unit);
      string feedback = session.FeedbackFor(state);
      if (editor == null || apply == null || cancel == null) feedback = "Required template parts are missing.";
      SetValue(FeedbackPropertyKey, feedback);
      if (editor != null) {
        editor.IsEnabled = (session.IsEditing || session.CanStart) && apply != null && cancel != null;
        editor.IsReadOnly = !session.IsEditing;
        if (!session.IsEditing) editor.Text = value;
      }
      if (apply != null) apply.IsEnabled = session.IsEditing;
      if (cancel != null) cancel.IsEnabled = session.IsEditing;
    }
  }
}
