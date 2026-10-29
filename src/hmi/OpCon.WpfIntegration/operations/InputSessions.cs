using System;
using System.Globalization;
using System.Threading;

namespace OpCon.WpfIntegration.Operations
{
  // Local input lifetimes only. No PLC transport, native event simulation or retry queue.
  internal abstract class InputSession
  {
    private readonly int thread = Thread.CurrentThread.ManagedThreadId;
    protected bool starting;
    protected string deferredCancel;
    protected bool ending;
    protected OperationContext blocked;
    public InputReceipt LastReceipt { get; protected set; }
    public OperationContext LastReceiptContext { get; protected set; }
    public event EventHandler Changed;
    protected void VerifyThread()
    { if (Thread.CurrentThread.ManagedThreadId != thread) throw new InvalidOperationException("Operation ports must use the owning UI thread."); }
    protected void Notify() { var handler = Changed; if (handler != null) handler(this, EventArgs.Empty); }
    protected InputReceipt Call(Func<InputReceipt> operation, OperationContext context)
    {
      InputReceipt result;
      try { result = operation() ?? InputReceipt.Unknown("Adapter returned no receipt."); }
      catch (Exception error) { result = InputReceipt.Unknown(error.GetType().Name + ": " + error.Message); }
      if (result.Disposition == InputDisposition.Unknown) blocked = context;
      // An attempted release must not conceal an unknown start/submit result.
      if (LastReceipt == null || LastReceipt.Disposition != InputDisposition.Unknown ||
        !context.Equals(LastReceiptContext) || result.Disposition == InputDisposition.Unknown)
      { LastReceipt = result; LastReceiptContext = context; }
      return result;
    }
    protected bool Permitted(OperationState state)
    { return !starting && !ending && state != null && state.CanStart && !state.Context.Equals(blocked); }
    protected void ReadFailed(Exception error, OperationContext context)
    {
      LastReceipt = InputReceipt.Unknown("State unavailable: " + error.GetType().Name);
      LastReceiptContext = context; if (context != null) blocked = context;
    }
    public string FeedbackFor(OperationState state)
    {
      if (LastReceipt != null && (state == null || state.Context.Equals(LastReceiptContext))) return LastReceipt.Message;
      return state == null ? "No operation adapter." : state.Feedback;
    }
  }

  internal sealed class ManualInputSession : InputSession, IDisposable
  {
    private IManualOperation port, activePort;
    private OperationContext activeContext;
    private Guid inputId;
    public OperationState State { get; private set; }
    public bool IsPressed { get { return activePort != null; } }
    public bool CanStart { get { return !IsPressed && Permitted(State); } }

    public void Bind(IManualOperation value)
    {
      VerifyThread();
      if (port != null) port.StateChanged -= PortChanged;
      Cancel("binding changed"); port = value;
      if (port != null) port.StateChanged += PortChanged;
      Observe();
    }
    private void PortChanged(object sender, EventArgs e) { VerifyThread(); Observe(); }
    private void Observe()
    {
      var previous = State;
      try { State = port == null ? null : port.State; }
      catch (Exception error) { State = null; ReadFailed(error, previous == null ? null : previous.Context); }
      if (IsPressed && (State == null || !State.CanContinue || !State.Context.Equals(activeContext)))
        Cancel("availability or context changed");
      Notify();
    }
    public bool Begin()
    {
      VerifyThread(); Observe(); if (!CanStart) return false;
      activePort = port; activeContext = State.Context; inputId = Guid.NewGuid();
      starting = true; deferredCancel = null;
      var capturedPort = activePort; var capturedContext = activeContext; var capturedId = inputId;
      InputReceipt result;
      try { result = Call(() => capturedPort.BeginPress(capturedId, capturedContext), capturedContext); }
      finally { starting = false; }
      if (!result.MayContinue && result.Disposition != InputDisposition.Unknown)
      { activePort = null; activeContext = null; }
      if (IsPressed && (deferredCancel != null || !result.MayContinue || State == null ||
        !State.CanContinue || !State.Context.Equals(activeContext)))
        Cancel(deferredCancel ?? "start failed or context changed");
      Notify(); return IsPressed;
    }
    public void Cancel(string reason)
    {
      VerifyThread();
      if (starting) { deferredCancel = reason; return; }
      if (activePort == null) return;
      var capturedPort = activePort; var capturedContext = activeContext; var capturedId = inputId;
      activePort = null; activeContext = null; ending = true;
      try { Call(() => capturedPort.EndPress(capturedId, capturedContext, reason), capturedContext); }
      finally { ending = false; }
      Notify();
    }
    public void Dispose() { Bind(null); }
  }

  internal sealed class ParameterInputSession : InputSession, IDisposable
  {
    private IParameterOperation port, editPort;
    private OperationContext editContext;
    private Guid inputId;
    public ParameterState State { get; private set; }
    public bool IsEditing { get { return editPort != null; } }
    public bool CanStart { get { return !IsEditing && Permitted(State); } }

    public void Bind(IParameterOperation value)
    {
      VerifyThread();
      if (port != null) port.StateChanged -= PortChanged;
      Cancel("binding changed"); port = value;
      if (port != null) port.StateChanged += PortChanged;
      Observe();
    }
    private void PortChanged(object sender, EventArgs e) { VerifyThread(); Observe(); }
    private void Observe()
    {
      var previous = State;
      try { State = port == null ? null : port.State; }
      catch (Exception error) { State = null; ReadFailed(error, previous == null ? null : previous.Context); }
      if (IsEditing && (State == null || !State.CanContinue || !State.Context.Equals(editContext)))
        Cancel("availability or context changed");
      Notify();
    }
    public bool Begin()
    {
      VerifyThread(); Observe(); if (!CanStart) return false;
      editPort = port; editContext = State.Context; inputId = Guid.NewGuid();
      starting = true; deferredCancel = null;
      var capturedPort = editPort; var capturedContext = editContext; var capturedId = inputId;
      InputReceipt result;
      try { result = Call(() => capturedPort.BeginEdit(capturedId, capturedContext), capturedContext); }
      finally { starting = false; }
      if (!result.MayContinue && result.Disposition != InputDisposition.Unknown)
      { editPort = null; editContext = null; }
      if (IsEditing && (deferredCancel != null || !result.MayContinue || State == null ||
        !State.CanContinue || !State.Context.Equals(editContext)))
        Cancel(deferredCancel ?? "edit start failed or context changed");
      Notify(); return IsEditing;
    }
    public bool Submit(string text, CultureInfo culture)
    {
      VerifyThread(); if (starting || ending) return false;
      Observe(); if (!IsEditing || State == null) return false;
      decimal value;
      const NumberStyles style = NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint |
        NumberStyles.AllowLeadingWhite | NumberStyles.AllowTrailingWhite;
      if (!Decimal.TryParse(text, style, culture, out value) || value < State.Minimum || value > State.Maximum)
      {
        LastReceipt = InputReceipt.Denied("Invalid number or outside configured limits.");
        LastReceiptContext = State.Context; Notify(); return false;
      }
      var capturedPort = editPort; var capturedContext = editContext; var capturedId = inputId;
      editPort = null; editContext = null; ending = true;
      InputReceipt result;
      try { result = Call(() => capturedPort.Submit(capturedId, capturedContext, value), capturedContext); }
      finally { ending = false; }
      Observe(); return result.MayContinue;
    }
    public void Cancel(string reason)
    {
      VerifyThread();
      if (starting) { deferredCancel = reason; return; }
      if (editPort == null) return;
      var capturedPort = editPort; var capturedContext = editContext; var capturedId = inputId;
      editPort = null; editContext = null; ending = true;
      try { Call(() => capturedPort.CancelEdit(capturedId, capturedContext, reason), capturedContext); }
      finally { ending = false; }
      Notify();
    }
    public void Dispose() { Bind(null); }
  }
}
