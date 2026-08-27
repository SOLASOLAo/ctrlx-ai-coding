namespace CtrlX.OpCon.Runner.Broker.Infrastructure;

public sealed class BrokerInfrastructureException : Exception
{
    public BrokerInfrastructureException(string reasonCode, string message)
        : base(message)
    {
        ReasonCode = reasonCode;
    }

    public BrokerInfrastructureException(string reasonCode, string message, Exception innerException)
        : base(message, innerException)
    {
        ReasonCode = reasonCode;
    }

    public string ReasonCode { get; }
}
