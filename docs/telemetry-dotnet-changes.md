# OpenTelemetry — .NET Service Changes

Each of the 9 .NET services needs these changes to emit traces to Grafana Tempo.

## NuGet Packages to Add

Add to each service's `.csproj` (the API project, not domain/infrastructure layers):

```xml
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.Http" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.EntityFrameworkCore" Version="1.0.0-beta.12" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.9.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.Runtime" Version="1.9.0" />
```

## Program.cs Change

Add this block **after** `builder.Services.AddControllers()` and **before** `builder.Build()`:

```csharp
// OpenTelemetry tracing
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .SetResourceBuilder(
            ResourceBuilder.CreateDefault()
                .AddService(
                    serviceName: builder.Configuration["ServiceName"] ?? "dhanman-unknown",
                    serviceVersion: "1.0.0"
                )
        )
        .AddAspNetCoreInstrumentation(opts =>
        {
            opts.RecordException = true;
            opts.Filter = ctx => ctx.Request.Path != "/health";
        })
        .AddHttpClientInstrumentation(opts => opts.RecordException = true)
        .AddEntityFrameworkCoreInstrumentation(opts => opts.SetDbStatementForText = true)
        .AddOtlpExporter(opts =>
        {
            opts.Endpoint = new Uri(
                builder.Configuration["OpenTelemetry:OtlpEndpoint"]
                ?? "http://127.0.0.1:4317"
            );
            opts.Protocol = OtlpExportProtocol.Grpc;
        })
    );
```

Required using statements at top of `Program.cs`:
```csharp
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Exporter;
```

## appsettings.Production.json

Add to each service (or inject via Vault — see below):

```json
{
  "ServiceName": "dhanman-common",
  "OpenTelemetry": {
    "OtlpEndpoint": "http://127.0.0.1:4317"
  }
}
```

Change `"dhanman-common"` to match the actual service name for each:

| Port | ServiceName value |
|------|-------------------|
| 5100 | `dhanman-common` |
| 5101 | `dhanman-sales` |
| 5102 | `dhanman-purchase` |
| 5103 | `dhanman-inventory` |
| 5104 | `dhanman-payroll` |
| 5105 | `dhanman-community` |
| 5106 | `dhanman-payment` |
| 5107 | `dhanman-document` |
| 5108 | `dhanman-agent` |

## MassTransit Tracing (optional but useful)

If you want RabbitMQ message spans to appear in traces, add this NuGet package:

```xml
<PackageReference Include="MassTransit.OpenTelemetry" Version="8.3.6" />
```

And add `.AddSource("MassTransit")` inside `.WithTracing(...)`:

```csharp
.WithTracing(tracing => tracing
    ...
    .AddSource("MassTransit")   // ← add this line
    .AddOtlpExporter(...)
)
```

## What you see in Grafana after this

- **Explore → Tempo** — search traces by service name, duration, status
- **Trace view** — waterfall diagram showing each span: HTTP → EF Core query → RabbitMQ publish
- **Service graph** — which services call which (auto-generated)
- Grafana can correlate: click a Loki log line → jump to the trace for that request

## Deploying via Jenkins

No infrastructure change needed per deploy — the OTLP endpoint `http://127.0.0.1:4317` is constant. Just rebuild and redeploy each service via the existing Jenkins pipeline after adding the NuGet packages and Program.cs change.
