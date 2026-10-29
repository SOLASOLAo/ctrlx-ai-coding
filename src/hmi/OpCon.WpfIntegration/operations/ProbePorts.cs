using System;
using System.Collections.Generic;
using OpCon.WpfIntegration.Operations;

// This file belongs to the sample/test executable, never the reusable control DLL.
// It records local intent only. It does not simulate native permissions, a PLC or a robot.
internal sealed class InputJournal
{
  public readonly List<string> Entries = new List<string>();
  public int Count { get; private set; }
  public event EventHandler Changed;
  public void Record(string text)
  {
    Count++; Entries.Add(Count + "  " + text);
    if (Entries.Count > 100) Entries.RemoveAt(0);
    var handler = Changed; if (handler != null) handler(this, EventArgs.Empty);
  }
}

internal sealed class ProbeManualPort : IManualOperation
{
  private readonly InputJournal journal;
  private Guid active;
  private OperationContext activeContext;
  private OperationState state;
  public int Begins, Ends;
  public Action DuringBegin = null;
  public bool ThrowOnBegin = false, ThrowOnEnd = false;
  public OperationState State { get { return state; } }
  public event EventHandler StateChanged;
  public int SubscriberCount { get { return StateChanged == null ? 0 : StateChanged.GetInvocationList().Length; } }
  public ProbeManualPort(InputJournal journal, string binding)
  {
    this.journal = journal;
    state = new OperationState(new OperationContext(binding, 1), OperationOrigin.LocalInputProbe, true,
      "Local input probe only; PLC not connected.");
  }
  public void SetAvailable(bool available, bool newGeneration)
  {
    state = new OperationState(new OperationContext(state.Context.Binding,
      state.Context.Generation + (newGeneration ? 1 : 0)), OperationOrigin.LocalInputProbe, available,
      available ? "Local input probe ready; PLC not connected." : "Local input probe unavailable.");
    var handler = StateChanged; if (handler != null) handler(this, EventArgs.Empty);
  }
  public void SetReadiness(bool canStart, bool canContinue)
  {
    state = new OperationState(state.Context, OperationOrigin.LocalInputProbe, canStart,
      "Local readiness probe; PLC not connected.", canContinue);
    var handler = StateChanged; if (handler != null) handler(this, EventArgs.Empty);
  }
  public InputReceipt BeginPress(Guid id, OperationContext context)
  {
    if (!state.CanStart || !state.Context.Equals(context) || active != Guid.Empty) return InputReceipt.Denied("Probe start denied.");
    active = id; activeContext = context; Begins++;
    journal.Record(context.Binding + " / press / " + id.ToString("N"));
    if (DuringBegin != null) DuringBegin();
    if (ThrowOnBegin) throw new InvalidOperationException("Injected local start exception.");
    return new InputReceipt(InputDisposition.RecordedLocally, "Press intent recorded locally; PLC not connected.");
  }
  public InputReceipt EndPress(Guid id, OperationContext context, string reason)
  {
    if (active == id && context.Equals(activeContext)) {
      active = Guid.Empty; activeContext = null; Ends++;
      journal.Record(context.Binding + " / release / " + reason);
      if (ThrowOnEnd) throw new InvalidOperationException("Injected local end exception.");
    }
    return new InputReceipt(InputDisposition.RecordedLocally, "Release intent recorded locally; PLC not connected.");
  }
}

internal sealed class ProbeParameterPort : IParameterOperation
{
  private readonly InputJournal journal;
  private Guid active;
  private OperationContext activeContext;
  private ParameterState state;
  public int Begins, Submits, Cancels;
  public decimal? LastSubmission;
  public Action DuringBegin = null;
  public bool ThrowOnSubmit = false;
  public ParameterState State { get { return state; } }
  public event EventHandler StateChanged;
  public int SubscriberCount { get { return StateChanged == null ? 0 : StateChanged.GetInvocationList().Length; } }
  public ProbeParameterPort(InputJournal journal, string binding)
  {
    this.journal = journal;
    state = new ParameterState(new OperationContext(binding, 1), OperationOrigin.LocalInputProbe, true,
      "Local sample value; PLC not connected.", 12.5m, 0m, 100m, "mm");
  }
  public void SetAvailable(bool available, bool newGeneration)
  {
    state = new ParameterState(new OperationContext(state.Context.Binding,
      state.Context.Generation + (newGeneration ? 1 : 0)), OperationOrigin.LocalInputProbe, available,
      available ? "Local input probe ready; PLC not connected." : "Local input probe unavailable.",
      available ? (decimal?)12.5m : null, 0m, 100m, "mm");
    var handler = StateChanged; if (handler != null) handler(this, EventArgs.Empty);
  }
  public void SetReadiness(bool canStart, bool canContinue)
  {
    state = new ParameterState(state.Context, OperationOrigin.LocalInputProbe, canStart,
      "Local readiness probe; PLC not connected.", state.Value, state.Minimum, state.Maximum, state.Unit, canContinue);
    var handler = StateChanged; if (handler != null) handler(this, EventArgs.Empty);
  }
  public InputReceipt BeginEdit(Guid id, OperationContext context)
  {
    if (!state.CanStart || !state.Context.Equals(context) || active != Guid.Empty) return InputReceipt.Denied("Probe edit denied.");
    active = id; activeContext = context; Begins++;
    journal.Record(context.Binding + " / begin edit");
    if (DuringBegin != null) DuringBegin();
    return new InputReceipt(InputDisposition.RecordedLocally, "Edit intent recorded locally; PLC not connected.");
  }
  public InputReceipt Submit(Guid id, OperationContext context, decimal value)
  {
    if (!state.CanContinue || !state.Context.Equals(context) || active != id || !context.Equals(activeContext) ||
      value < state.Minimum || value > state.Maximum) return InputReceipt.Denied("Probe submission denied.");
    active = Guid.Empty; activeContext = null; Submits++; LastSubmission = value;
    journal.Record(context.Binding + " / submit intent / " + value.ToString(System.Globalization.CultureInfo.InvariantCulture));
    if (ThrowOnSubmit) throw new InvalidOperationException("Injected local submission exception.");
    // Deliberately keep Value unchanged: a recorded input is not a PLC readback.
    return new InputReceipt(InputDisposition.RecordedLocally, "Submit intent recorded locally; PLC not connected.");
  }
  public InputReceipt CancelEdit(Guid id, OperationContext context, string reason)
  {
    if (active == id && context.Equals(activeContext)) {
      active = Guid.Empty; activeContext = null; Cancels++;
      journal.Record(context.Binding + " / cancel edit / " + reason);
    }
    return new InputReceipt(InputDisposition.RecordedLocally, "Edit cancelled locally; PLC not connected.");
  }
}
