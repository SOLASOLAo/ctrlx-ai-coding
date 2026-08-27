# Controlled Runner Core

This directory contains the product-owned .NET 8 control and client side of
Runner P1.2. It consumes an immutable Stage 2 action and may connect only to an
already-running interactive-user-session Broker over a named pipe.

It has no command that launches PLE, `codesys-persistent`, a watcher, REST, or
any online PLC operation. If the Broker is absent, the action is sealed as a
structured `BLOCKED_SESSION_UNAVAILABLE` result.

```powershell
dotnet build .\src\runner\CtrlX.OpCon.Runner.Cli\CtrlX.OpCon.Runner.Cli.csproj -c Release
dotnet run --project .\tests\runner\CtrlX.OpCon.Runner.SelfTest\CtrlX.OpCon.Runner.SelfTest.csproj -c Release
```

P1.2a provides the action validator, idempotency ledger, cross-process client
leases, named-pipe protocol and existing evidence-producer integration. P1.2b
will implement the interactive Broker/Agent that is the sole MCP stdio and PLE
owner, with Broker-side Pipe ACL/trusted registration, typed action execution
and explicit cancellation-or-completion semantics for long Build operations.
