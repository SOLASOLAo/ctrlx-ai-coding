using System;

namespace OpCon.WpfIntegration.Operations
{
  // This is our adapter contract. It is not a claim that these methods exist in OpCon.
  public enum OperationOrigin { Unavailable, LocalInputProbe, NativeHmi }
  public enum InputDisposition { Denied, RecordedLocally, ForwardedToNative, Unknown }

  public sealed class OperationContext : IEquatable<OperationContext>
  {
    public string Binding { get; private set; }
    public long Generation { get; private set; }
    public OperationContext(string binding, long generation)
    {
      if (String.IsNullOrWhiteSpace(binding)) throw new ArgumentException("A binding is required.", "binding");
      if (generation < 0) throw new ArgumentOutOfRangeException("generation");
      Binding = binding; Generation = generation;
    }
    public bool Equals(OperationContext other)
    { return other != null && Binding == other.Binding && Generation == other.Generation; }
    public override bool Equals(object other) { return Equals(other as OperationContext); }
    public override int GetHashCode() { return Binding.GetHashCode() ^ Generation.GetHashCode(); }
  }

  public class OperationState
  {
    public OperationContext Context { get; private set; }
    public OperationOrigin Origin { get; private set; }
    public bool CanStart { get; private set; }
    public bool CanContinue { get; private set; }
    public string Feedback { get; private set; }
    // CanStart must combine freshness, authorization, token, release and native busy rules.
    // The adapter must check them again when receiving an operation, including BeginEdit.
    public OperationState(OperationContext context, OperationOrigin origin, bool canStart, string feedback, bool? canContinue = null)
    {
      if (context == null) throw new ArgumentNullException("context");
      if (!Enum.IsDefined(typeof(OperationOrigin), origin)) throw new ArgumentOutOfRangeException("origin");
      Context = context; Origin = origin;
      CanStart = canStart && origin != OperationOrigin.Unavailable;
      CanContinue = (canContinue ?? canStart) && origin != OperationOrigin.Unavailable;
      Feedback = feedback ?? "";
    }
  }

  public sealed class ParameterState : OperationState
  {
    public decimal? Value { get; private set; }
    public decimal Minimum { get; private set; }
    public decimal Maximum { get; private set; }
    public string Unit { get; private set; }
    public ParameterState(OperationContext context, OperationOrigin origin, bool canStart, string feedback,
      decimal? value, decimal minimum, decimal maximum, string unit, bool? canContinue = null)
      : base(context, origin, canStart && value.HasValue, feedback, (canContinue ?? canStart) && value.HasValue)
    {
      if (minimum > maximum) throw new ArgumentException("Minimum exceeds maximum.");
      Value = value; Minimum = minimum; Maximum = maximum; Unit = unit ?? "";
    }
  }

  public sealed class InputReceipt
  {
    public InputDisposition Disposition { get; private set; }
    public string Message { get; private set; }
    public bool MayContinue
    { get { return Disposition == InputDisposition.RecordedLocally || Disposition == InputDisposition.ForwardedToNative; } }
    public InputReceipt(InputDisposition disposition, string message)
    {
      if (!Enum.IsDefined(typeof(InputDisposition), disposition)) throw new ArgumentOutOfRangeException("disposition");
      Disposition = disposition; Message = message ?? "";
    }
    public static InputReceipt Denied(string reason) { return new InputReceipt(InputDisposition.Denied, reason); }
    public static InputReceipt Unknown(string reason) { return new InputReceipt(InputDisposition.Unknown, reason); }
  }

  // UI-thread-only, synchronous, bounded calls. State is an immutable cached snapshot.
  // A forwarded receipt means HMI dispatch, never PLC acceptance or completion.
  public interface IParameterOperation
  {
    ParameterState State { get; }
    event EventHandler StateChanged;
    InputReceipt BeginEdit(Guid inputId, OperationContext context);
    InputReceipt Submit(Guid inputId, OperationContext context, decimal value);
    InputReceipt CancelEdit(Guid inputId, OperationContext context, string reason);
  }

  public interface IManualOperation
  {
    OperationState State { get; }
    event EventHandler StateChanged;
    InputReceipt BeginPress(Guid inputId, OperationContext context);
    // Release is bound to the original context. Unknown IDs must be a harmless no-op.
    // A stale context must never be resolved to the currently selected Unit.
    InputReceipt EndPress(Guid inputId, OperationContext context, string reason);
  }
}
