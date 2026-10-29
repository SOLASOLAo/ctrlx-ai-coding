using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using VisiWinNET.DataAccess;

namespace OpCon.WpfIntegration
{
  // A cached good quality is insufficient after reconnect or a paused UI thread.
  // Require an observed PLC heartbeat change in the current attachment period.
  internal sealed class FreshnessGate
  {
    private object last;
    private long changedAt;
    private long sampledAt = -1;
    private bool seen, advanced;
    internal void Reset() { seen = advanced = false; last = null; changedAt = 0; sampledAt = -1; }
    internal bool Observe(object heartbeat, bool good, long nowMs, int timeoutMs)
    {
      if (!good || heartbeat == null) { Reset(); return false; }
      if (sampledAt >= 0 && (nowMs < sampledAt || nowMs - sampledAt > timeoutMs)) Reset();
      sampledAt = nowMs;
      if (!seen) { last = heartbeat; seen = true; changedAt = nowMs; return false; }
      if (!Object.Equals(last, heartbeat))
      { last = heartbeat; changedAt = nowMs; advanced = true; }
      return advanced && nowMs >= changedAt && nowMs - changedAt <= timeoutMs;
    }
  }

  internal sealed class NativeReadSet : IDisposable
  {
    private readonly Dictionary<string, Item> items = new Dictionary<string, Item>(StringComparer.Ordinal);
    private readonly string block = "OpCon.WpfIntegration:" + Guid.NewGuid().ToString("N");
    private readonly string heartbeat;
    private readonly FreshnessGate freshness = new FreshnessGate();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private bool disposed;
    private bool fresh;
    private long lastPoll;
    private int timeout;
    internal bool IsFresh { get { return !disposed && fresh && clock.ElapsedMilliseconds - lastPoll <= timeout; } }
    internal int Count { get { return items.Count; } }

    internal static string FullName(string prefix, string relative)
    {
      if (String.IsNullOrWhiteSpace(prefix) || String.IsNullOrWhiteSpace(relative) ||
          prefix.Length > 256 || relative.Length > 256 ||
          prefix.Any(Char.IsControl) || relative.Any(Char.IsControl) ||
          relative.StartsWith(".", StringComparison.Ordinal) || relative.EndsWith(".", StringComparison.Ordinal))
        throw new ArgumentException("Use a nonempty item prefix and relative binding path");
      return prefix.TrimEnd('.') + "." + relative;
    }

    internal NativeReadSet(string prefix, string heartbeatPath, IEnumerable<string> paths)
    {
      heartbeat = heartbeatPath;
      var selected = paths.Concat(new[] { heartbeatPath }).Distinct(StringComparer.Ordinal).ToArray();
      if (selected.Length > 64) throw new ArgumentException("At most 64 display/heartbeat items per host");
      var names = selected.ToDictionary(p => p, p => FullName(prefix, p), StringComparer.Ordinal);
      foreach (string path in selected) items.Add(path, new Item { Name = names[path] });
    }

    internal void Attach()
    {
      if (disposed) throw new ObjectDisposedException("NativeReadSet");
      if (items.Values.All(item => item.IsAttached)) return;
      bool complete = false;
      MultiItemActivator.ActivationBlockStart(block);
      try
      {
        foreach (var item in items.Values) if (!item.IsAttached) item.Attach();
        complete = true;
      }
      finally { MultiItemActivator.ActivationBlockFinished(block, complete); }
    }

    private static bool Good(Item item)
    { return item.IsAttached && (item.Quality.Value & 0xc0) == 0xc0; }

    internal void Poll(int timeoutMs)
    {
      var item = items[heartbeat];
      long now = clock.ElapsedMilliseconds;
      timeout = timeoutMs; lastPoll = now;
      fresh = freshness.Observe(item.Value, Good(item), now, timeoutMs);
    }

    internal string Display(string path, string format)
    {
      var item = items[path];
      if (!IsFresh || !Good(item) || item.Value == null) return "—";
      var value = item.Value as IFormattable;
      return value == null ? Convert.ToString(item.Value, CultureInfo.CurrentCulture) :
        value.ToString(String.IsNullOrEmpty(format) ? null : format, CultureInfo.CurrentCulture);
    }

    internal void Invalidate() { fresh = false; freshness.Reset(); }

    internal void Detach()
    {
      Invalidate();
      if (!items.Values.Any(item => item.IsAttached)) return;
      bool complete = false;
      MultiItemActivator.DeactivationBlockStart(block);
      try { foreach (var item in items.Values) if (item.IsAttached) item.Detach(); complete = true; }
      finally { MultiItemActivator.DeactivationBlockFinished(block, complete); }
    }

    public void Dispose()
    {
      if (disposed) return;
      Exception firstError = null;
      try { Detach(); } catch (Exception error) { firstError = error; }
      foreach (var item in items.Values)
      { try { item.Dispose(); } catch (Exception error) { if (firstError == null) firstError = error; } }
      disposed = true;
      if (firstError != null) throw new InvalidOperationException("Display item cleanup failed", firstError);
    }
  }
}
