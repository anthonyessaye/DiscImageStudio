using DiscImageStudio.Core;
using DiscImageStudio.BluRay;
using DiscImageStudio.Cd;
using DiscImageStudio.Dvd;
using DiscImageStudio.Services;

namespace DiscImageStudio;

internal static class ConsoleModuleRunner
{
    internal static DiscModuleCatalog Catalog { get; } = new(
        [new CdDiscModule(), new DvdDiscModule(), new BluRayDiscModule(BluRayImageLoader.Load)]);

    internal static int Run(string[] arguments)
    {
        DiscJobRequest request = new(arguments[0], arguments.Skip(1));
        IOpticalDiscModule module = Catalog.Resolve(request.Command);
        using CancellationTokenSource cancellation = new();
        ConsoleCancelEventHandler cancelHandler = (_, e) =>
        {
            if (!module.Descriptor.SupportsCancellation) return;
            e.Cancel = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            DiscJobResult result = module.ExecuteAsync(request, new ConsoleProgress(), cancellation.Token)
                .GetAwaiter().GetResult();
            if (!string.IsNullOrWhiteSpace(result.Summary)) Console.WriteLine(result.Summary);
            return result.ExitCode;
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private sealed class ConsoleProgress : IProgress<DiscJobProgress>
    {
        // Set by the macOS app, which reads progress as data instead of parsing log text.
        private static readonly bool JsonProgress =
            Environment.GetEnvironmentVariable("DISC_IMAGE_STUDIO_JSON_PROGRESS") == "1";

        public void Report(DiscJobProgress value)
        {
            if (JsonProgress)
            {
                Console.WriteLine("@@dis-progress " + System.Text.Json.JsonSerializer.Serialize(new
                {
                    moduleId = value.ModuleId,
                    stage = value.Stage,
                    message = value.Message,
                    fraction = value.Fraction,
                    completedUnits = value.CompletedUnits,
                    totalUnits = value.TotalUnits,
                }));
                return;
            }

            if (!string.IsNullOrWhiteSpace(value.Message)) Console.WriteLine(value.Message);
        }
    }
}
