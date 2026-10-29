using System.Windows;

namespace OpCon.WpfIntegration
{
  /// <summary>Reserves a WPF rectangle for an existing sibling native control.</summary>
  public static class NativeSlot
  {
    public static readonly DependencyProperty ControlNameProperty = DependencyProperty.RegisterAttached(
      "ControlName", typeof(string), typeof(NativeSlot), new PropertyMetadata(""));
    public static string GetControlName(DependencyObject target) { return (string)target.GetValue(ControlNameProperty); }
    public static void SetControlName(DependencyObject target, string value) { target.SetValue(ControlNameProperty, value); }
  }

  /// <summary>One-way display binding through the already running VisiWin item system.</summary>
  public static class NativeValue
  {
    public static readonly DependencyProperty PathProperty = DependencyProperty.RegisterAttached(
      "Path", typeof(string), typeof(NativeValue), new PropertyMetadata(""));
    public static readonly DependencyProperty FormatProperty = DependencyProperty.RegisterAttached(
      "Format", typeof(string), typeof(NativeValue), new PropertyMetadata(""));
    public static string GetPath(DependencyObject target) { return (string)target.GetValue(PathProperty); }
    public static void SetPath(DependencyObject target, string value) { target.SetValue(PathProperty, value); }
    public static string GetFormat(DependencyObject target) { return (string)target.GetValue(FormatProperty); }
    public static void SetFormat(DependencyObject target, string value) { target.SetValue(FormatProperty, value); }
  }

  /// <summary>Uses the current HMI language without changing it or writing PLC data.</summary>
  public static class NativeText
  {
    public static readonly DependencyProperty GroupProperty = DependencyProperty.RegisterAttached(
      "Group", typeof(string), typeof(NativeText), new PropertyMetadata(""));
    public static readonly DependencyProperty KeyProperty = DependencyProperty.RegisterAttached(
      "Key", typeof(string), typeof(NativeText), new PropertyMetadata(""));
    public static string GetGroup(DependencyObject target) { return (string)target.GetValue(GroupProperty); }
    public static void SetGroup(DependencyObject target, string value) { target.SetValue(GroupProperty, value); }
    public static string GetKey(DependencyObject target) { return (string)target.GetValue(KeyProperty); }
    public static void SetKey(DependencyObject target, string value) { target.SetValue(KeyProperty, value); }
  }
}
