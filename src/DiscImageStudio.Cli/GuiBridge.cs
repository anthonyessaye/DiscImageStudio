using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using DiscImageStudio.BluRay;
using DiscImageStudio.Cd;
using DiscImageStudio.Core;
using DiscImageStudio.Core.Calibration;
using DiscImageStudio.Dvd;
using DiscImageStudio.ImageIO;
using DiscImageStudio.Services;

namespace DiscImageStudio.Cli;

/// <summary>Commands for the macOS app: the engine features that the Windows app calls in
/// process and the disc modules don't expose. Each writes one JSON document to stdout and
/// reports failure the usual way (message on stderr, non-zero exit). They stay out of the
/// module catalog and --help because they are an app interface, not a user-facing one.</summary>
internal static partial class GuiBridge
{
    private const string Prefix = "gui-";
    private const double PhysicalHoleRadiusMm = 7.5;
    private const int RectifiedPhotoSize = 1400;

    // Same acceptance rule the Windows calibration page applies before a candidate can be used.
    private const double MaxAcceptedRmsMm = 0.35;
    private const double MaxAcceptedPointErrorMm = 0.8;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    internal static bool IsBridgeCommand(string command)
        => command.StartsWith(Prefix, StringComparison.Ordinal);

    internal static int Run(string[] args)
    {
        Options options = new(args.Skip(1));
        using CancellationTokenSource cancellation = new();
        ConsoleCancelEventHandler onCancel = (_, e) =>
        {
            e.Cancel = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += onCancel;
        try
        {
            object result = args[0] switch
            {
                "gui-presets" => Presets(options),
                "gui-project-validate" => ProjectValidate(options),
                "gui-drawing-plan" => DrawingPlan(options),
                "gui-bd-preview" => BluRayPreview(options, cancellation.Token),
                "gui-dvd-tone-preview" => DvdTonePreviewCommand(options, cancellation.Token),
                "gui-artifact-info" => ArtifactInfo(options),
                "gui-sweep-generate" => SweepGenerate(options, cancellation.Token),
                "gui-sweep-simulate" => SweepSimulate(options, cancellation.Token),
                "gui-sweep-read" => SweepRead(options, cancellation.Token),
                "gui-preset-save" => PresetSave(options),
                "gui-preview-overlay" => PreviewOverlay(options, cancellation.Token),
                "gui-calibration-create" => CalibrationCreate(options, cancellation.Token),
                "gui-calibration-info" => CalibrationInfo(options),
                "gui-calibration-save" => CalibrationSave(options),
                "gui-calibration-render" => CalibrationRender(options, cancellation.Token),
                "gui-calibration-generate" => CalibrationGenerate(options, cancellation.Token),
                "gui-calibration-fit" => CalibrationFit(options, cancellation.Token),
                "gui-photo-rectify" => PhotoRectify(options, cancellation.Token),
                _ => throw new ArgumentException($"Unknown command '{args[0]}'."),
            };
            Console.WriteLine(JsonSerializer.Serialize(result, Json));
            return 0;
        }
        finally
        {
            Console.CancelKeyPress -= onCancel;
        }
    }

    // ---- Presets and projects ----

    private static object Presets(Options options)
    {
        DiscPresetJsonDocument builtIn = DiscPresetJsonStore.LoadBuiltIn();
        string? userFile = options.Optional("user-file");
        return userFile is not null && File.Exists(userFile)
            ? DiscPresetJsonStore.Merge(builtIn, DiscPresetJsonStore.Load(userFile))
            : builtIn;
    }

    /// <summary>Runs the file through the real store, so a project written by the Mac app is
    /// known to open on Windows. Load throws with the reason if it wouldn't.</summary>
    private static object ProjectValidate(Options options)
    {
        ProjectDocument document = ProjectJsonStore.Load(options.Require("input"));
        ProjectJsonStore.Validate(document);
        return new { ok = true, schemaVersion = document.SchemaVersion };
    }

    // ---- Previews ----

    /// <summary>Where the picture is drawn once a files folder takes part of the disc.</summary>
    private static object DrawingPlan(Options options)
    {
        string family = options.Require("family");
        string dataDirectory = options.Require("data-dir");
        string? label = options.Optional("volume-label");
        bool outer = options.Require("file-position") == "outer";
        switch (family)
        {
            case "cd":
            {
                CdDataLayoutPlan plan = CdDataImageGenerator.PrepareLayout(dataDirectory,
                    new CdDiscParameters(options.Double("r0"), options.Double("r1"), options.Long("sectors")),
                    label ?? "CD_IMAGE", outer);
                return new { start = (long)plan.DrawingStartLba, end = (long)plan.DrawingEndLbaExclusive };
            }
            case "dvd":
            {
                DvdHybridStreamingPlan plan = DvdStreamingGenerator.PrepareHybrid(dataDirectory, DvdOptions(options),
                    label ?? "DISC_IMAGE", filesAtOuterRing: outer);
                return new { start = (long)plan.DrawingStartLba, end = (long)plan.DrawingStartLba + plan.DrawingSectors };
            }
            case "bd":
            {
                BluRayIsoPlan plan = BluRayIsoGenerator.PrepareDrawing(BluRayDisc(options, "r0", "r1"), dataDirectory,
                    label ?? "BD_IMAGE", filesAtOuterRing: outer);
                return new { start = (long)plan.DrawingStartSector, end = (long)plan.DrawingEndSectorExclusive };
            }
            default:
                throw new ArgumentException($"Unknown disc family '{family}'.");
        }
    }

    private static object BluRayPreview(Options options, CancellationToken token)
    {
        string mode = options.Require("mode");
        string input = options.Require("input");
        string output = Path.GetFullPath(options.Require("output"));
        int size = options.Int("size");
        if (mode == "projection")
        {
            BluRayDiscParameters disc = BluRayDisc(options, "r0", "r1");
            BluRayPreviewRenderer.RenderProjection(input, output, disc, size, options.Bool("invert"), Tone(options), token);
            return new { output, drawingStart = 0L, drawingEnd = (long)disc.TotalSectors, hasSidecar = false, hasFileRegion = false };
        }

        BluRayDiscParameters actual = BluRayDisc(options, "actual-r0", "actual-r1");
        switch (mode)
        {
            case "calibration":
            {
                BluRayDiscParameters generated = BluRayDisc(options, "r0", "r1");
                uint start = (uint)options.Long("drawing-start", 0);
                uint end = (uint)options.Long("drawing-end", generated.TotalSectors);
                BluRayPreviewRenderer.RenderCalibration(input, output, generated, actual, start, end, size,
                    options.Bool("invert"), token, Tone(options));
                return new { output, drawingStart = start, drawingEnd = end, hasSidecar = false, hasFileRegion = false };
            }
            case "readback":
            {
                // A finished ISO carries its own range in its sidecar; the current project
                // settings may have moved on since it was generated.
                BluRayIsoMetadata? metadata = BluRayIsoMetadata.TryLoad(input);
                uint start = metadata?.DrawingStartSector ?? 0;
                uint? end = metadata?.DrawingEndSectorExclusive;
                BluRayPreviewRenderer.RenderReadback(input, output, actual, size, token, start, end);
                return new
                {
                    output,
                    drawingStart = start,
                    drawingEnd = end ?? actual.TotalSectors,
                    hasSidecar = metadata is not null,
                    hasFileRegion = metadata?.UdfTimestamp is not null,
                };
            }
            default:
                throw new ArgumentException($"Unknown preview mode '{mode}'.");
        }
    }

    /// <summary>What a generated file's sidecar records, so a file made earlier or on another
    /// machine reads back with the geometry it was made with.</summary>
    private static object ArtifactInfo(Options options)
    {
        string input = options.Require("input");
        switch (options.Require("family"))
        {
            case "cd":
                if (input.EndsWith(".iso", StringComparison.OrdinalIgnoreCase))
                {
                    CdDataImageMetadata? data = CdDataImageMetadata.TryLoad(input);
                    return new
                    {
                        hasSidecar = data is not null,
                        innerRadiusMm = data?.Parameters.InnerRadiusMm,
                        outerRadiusMm = data?.Parameters.OuterRadiusMm,
                        sectors = data?.Parameters.Sectors,
                        drawingStart = (long?)data?.DrawingStartLba,
                        drawingEnd = (long?)data?.DrawingEndLbaExclusive,
                        hasFileRegion = data is not null,
                    };
                }
                CdTrackMetadata? track = CdTrackMetadata.TryLoad(input);
                return new
                {
                    hasSidecar = track is not null,
                    innerRadiusMm = track?.InnerRadiusMm,
                    outerRadiusMm = track?.OuterRadiusMm,
                    sectors = track?.Sectors,
                    interleaved = track?.Interleaved,
                    hasFileRegion = false,
                };
            case "dvd":
                DvdImageMetadata? dvd = DvdImageMetadata.TryLoad(input);
                return new
                {
                    hasSidecar = dvd is not null,
                    innerRadiusMm = dvd?.InnerRadiusMm,
                    outerRadiusMm = dvd?.OuterRadiusMm,
                    sectors = (long?)dvd?.TotalSectors,
                    pitchLinear = dvd?.PitchLinear,
                    pitchQuadratic = dvd?.PitchQuadratic,
                    pitchCubic = dvd?.PitchCubic,
                    drawingStart = (long?)dvd?.DrawingStartLba,
                    drawingEnd = (long?)dvd?.DrawingEndLbaExclusive,
                    hasFileRegion = dvd?.HasFileSystem ?? false,
                };
            case "bd":
                BluRayIsoMetadata? bd = BluRayIsoMetadata.TryLoad(input);
                return new
                {
                    hasSidecar = bd is not null,
                    drawingStart = (long?)bd?.DrawingStartSector,
                    drawingEnd = (long?)bd?.DrawingEndSectorExclusive,
                    hasFileRegion = bd?.UdfTimestamp is not null,
                };
            default:
                throw new ArgumentException("Unknown disc family.");
        }
    }

    /// <summary>The Design page's small tone preview for DVD.</summary>
    private static object DvdTonePreviewCommand(Options options, CancellationToken token)
    {
        string output = Path.GetFullPath(options.Require("output"));
        DvdTonePreview.Render(options.Require("input"), output,
            DvdOptions(options) with { Tone = Tone(options) }, options.Int("size"), options.Int("samples-per-sector"), token);
        return new { output };
    }

    /// <summary>Adds or replaces one preset in the user's preset file, which is then merged
    /// over the built-in list by gui-presets.</summary>
    private static object PresetSave(Options options)
    {
        string path = options.Require("user-file");
        DiscPresetJsonDocument document = File.Exists(path)
            ? DiscPresetJsonStore.Load(path)
            : DiscPresetJsonStore.CreateInitialUserDocument();
        string id = options.Require("id");
        string name = options.Require("name");
        string description = options.Optional("description") ?? name;
        double inner = options.Double("r0"), outer = options.Double("r1");
        string family = options.Require("family");
        document = family switch
        {
            "cd" => document with
            {
                CdPresets = [.. document.CdPresets.Where(p => p.Id != id),
                    new CdDiscPresetDefinition(id, name, description, options.Long("sectors"), inner, outer)],
            },
            "dvd" => document with
            {
                DvdPresets = [.. document.DvdPresets.Where(p => p.Id != id),
                    new DvdDiscPresetDefinition(id, name, description, (uint)options.Long("sectors"), inner, outer,
                        PitchLinear: options.Double("pitch-linear", 0),
                        PitchQuadratic: options.Double("pitch-quadratic", 0),
                        PitchCubic: options.Double("pitch-cubic", 0))],
            },
            "bd" => document with
            {
                BluRayPresets = [.. (document.BluRayPresets ?? []).Where(p => p.Id != id),
                    new BluRayDiscPresetDefinition(id, name, description, (uint)options.Long("sectors"), inner, outer,
                        options.Bool("invert"))],
            },
            _ => throw new ArgumentException($"Unknown disc family '{family}'."),
        };
        DiscPresetJsonStore.Save(path, document);
        return new { id };
    }

    /// <summary>Paints the area files occupy on a preview PNG. Presentation only: generated
    /// images never pass through here. The pixel-to-mm conventions differ per family because
    /// each renderer's own convention has to be matched.</summary>
    private static object PreviewOverlay(Options options, CancellationToken token)
    {
        string path = options.Require("input");
        uint start = (uint)options.Long("drawing-start");
        uint end = (uint)options.Long("drawing-end");
        double inner = options.Double("actual-r0"), outer = options.Double("actual-r1");
        double drawingInner, drawingOuter;
        bool dvdPixels = false;
        double? cdImageOuter = null;
        string family = options.Require("family");
        switch (family)
        {
            case "cd":
            {
                CdDiscParameters disc = new(inner, outer, options.Long("sectors"));
                disc.Validate();
                drawingInner = disc.RadiusFromByte((long)start * CdDiscParameters.BytesPerSector);
                drawingOuter = disc.RadiusFromByte((long)end * CdDiscParameters.BytesPerSector);
                cdImageOuter = disc.ImageOuterRadiusMm;
                break;
            }
            case "dvd":
            {
                DvdStreamingOptions disc = DvdOptions(options, "actual-r0", "actual-r1", "actual-pitch");
                disc.Validate();
                double length = disc.TotalSectors * 38688.0 * disc.ChannelBitLengthNm * 1e-6;
                DvdTrackGeometry geometry = DvdTrackGeometry.Create(disc.InnerRadiusMm, disc.OuterRadiusMm, length,
                    disc.PitchLinear, disc.PitchQuadratic, disc.PitchCubic);
                drawingInner = geometry.RadiusAtArcLength(length * ((double)start / disc.TotalSectors));
                drawingOuter = geometry.RadiusAtArcLength(length * ((double)end / disc.TotalSectors));
                dvdPixels = true;
                break;
            }
            case "bd":
            {
                BluRayDiscParameters disc = BluRayDisc(options, "actual-r0", "actual-r1");
                BluRayTrackGeometry geometry = new(disc);
                drawingInner = geometry.AtSector(start).RadiusMm;
                drawingOuter = geometry.AtSector(end).RadiusMm;
                break;
            }
            default:
                throw new ArgumentException($"Unknown disc family '{family}'.");
        }

        BgraRaster raster = RasterCodec.LoadBgra32(path);
        if (raster.Width != raster.Height) throw new ArgumentException("Disc previews must be square.");
        int size = raster.Width;
        double centre = cdImageOuter.HasValue ? size / 2.0 : (size - 1) / 2.0;
        double mmPerPixel = (cdImageOuter ?? outer) * 2 / (dvdPixels ? size - 1 : size);
        for (int y = 0; y < size; y++)
        {
            token.ThrowIfCancellationRequested();
            double dy = (y - centre) * mmPerPixel;
            for (int x = 0; x < size; x++)
            {
                double dx = (x - centre) * mmPerPixel;
                double r2 = dx * dx + dy * dy;
                if (r2 < inner * inner || r2 >= outer * outer
                    || (r2 >= drawingInner * drawingInner && r2 < drawingOuter * drawingOuter))
                    continue;
                int offset = (y * size + x) * 4;
                // #FACC15, the file-region colour in the preview legend.
                raster.Pixels[offset] = 21;
                raster.Pixels[offset + 1] = 204;
                raster.Pixels[offset + 2] = 250;
                raster.Pixels[offset + 3] = 255;
            }
        }
        RasterCodec.SavePng(path, size, size, raster.Pixels, grayscale: false);
        return new { output = path };
    }

    // ---- Calibration ----

    private static object CalibrationCreate(Options options, CancellationToken token)
    {
        string family = options.Require("family");
        CalibrationParameters parameters = family switch
        {
            "cd" => new(CalibrationDiscKind.Cd, options.Double("r0"), options.Double("r1"), options.Long("sectors"),
                CdDiscParameters.StandardLinearVelocityMmPerSecond),
            "dvd" => new(CalibrationDiscKind.Dvd, options.Double("r0"), options.Double("r1"), options.Long("sectors"),
                DvdStreamingOptions.StandardChannelBitLengthNm,
                options.Double("pitch-linear", 0), options.Double("pitch-quadratic", 0), options.Double("pitch-cubic", 0)),
            "bd" => BluRayCalibrationParameters(options),
            _ => throw new ArgumentException($"Unknown disc family '{family}'."),
        };
        ValidateOutput(parameters);
        CalibrationTarget target = CalibrationTarget.Create(parameters);
        CalibrationSession session = new(target, [], new(), options.Bool("cd-interleave", true));
        string sessionPath = Path.GetFullPath(options.Require("session"));
        CalibrationSessionJson.Save(sessionPath, session);
        return Describe(session, sessionPath);
    }

    private static CalibrationParameters BluRayCalibrationParameters(Options options)
    {
        BluRayDiscParameters disc = BluRayDisc(options, "r0", "r1");
        return new(CalibrationDiscKind.BluRay, disc.InnerRadiusMm, disc.OuterRadiusMm, disc.TotalSectors,
            BluRayDiscParameters.ChannelBitLengthNm,
            BluRayInvertMapping: options.Bool("invert"),
            DrawingStartSector: 0,
            DrawingEndSectorExclusive: disc.TotalSectors);
    }

    private static void ValidateOutput(CalibrationParameters p)
    {
        p.Validate();
        if (p.Kind == CalibrationDiscKind.Dvd)
            new DvdStreamingOptions(checked((uint)p.Sectors), p.InnerRadiusMm, p.OuterRadiusMm, p.LinearDensity, 0,
                PitchLinear: p.PitchLinear, PitchQuadratic: p.PitchQuadratic, PitchCubic: p.PitchCubic).Validate();
        else if (p.Kind == CalibrationDiscKind.Cd)
            new CdDiscParameters(p.InnerRadiusMm, p.OuterRadiusMm, p.Sectors, p.LinearDensity).Validate();
    }

    private static object CalibrationInfo(Options options)
    {
        string path = Path.GetFullPath(options.Require("session"));
        return Describe(CalibrationSessionJson.Load(path), path);
    }

    private static object Describe(CalibrationSession session, string path)
    {
        CalibrationParameters p = session.Target.Parameters;
        return new
        {
            sessionPath = path,
            id = session.Target.Id,
            parameters = p,
            canvasOuterRadiusMm = Math.Max(CalibrationReferencePattern.CanvasRadiusMm, p.OuterRadiusMm),
            cdInterleave = session.CdInterleave,
            fitOptions = session.FitOptions,
            photo = session.Photo,
        };
    }

    /// <summary>Stores the Mac app's photo, boundary and trace state in the session. The
    /// session's Validate decides whether it is acceptable, as it does on Windows.</summary>
    private static object CalibrationSave(Options options)
    {
        string path = Path.GetFullPath(options.Require("session"));
        CalibrationSession session = CalibrationSessionJson.Load(path);
        SaveRequest request = JsonSerializer.Deserialize<SaveRequest>(File.ReadAllText(options.Require("request")), Json)
            ?? throw new ArgumentException("The save request is empty.");
        CalibrationSession updated = session with
        {
            Photo = request.Photo,
            FitOptions = FitOptions(session, request.RadiusRangeMm, request.AutoRange, request.FitDvdPitch),
        };
        string destination = options.Optional("output") is { } output ? Path.GetFullPath(output) : path;
        CalibrationSessionJson.Save(destination, updated);
        return new { sessionPath = destination };
    }

    private static CalibrationFitOptions FitOptions(CalibrationSession session, double range, bool auto, bool fitPitch)
        => (session.FitOptions ?? new()) with
        {
            SearchCenter = session.FitOptions?.SearchCenter ?? session.Target.Parameters,
            RadiusRangeMm = range,
            FitDvdPitch = fitPitch,
            AdaptiveRobustScale = true,
            AutoRange = auto,
        };

    /// <summary>Renders the target as it should look on the disc, or with --encoding the
    /// source picture a burner would be given.</summary>
    private static object CalibrationRender(Options options, CancellationToken token)
    {
        CalibrationTarget target = CalibrationSessionJson.Load(options.Require("session")).Target;
        string output = Path.GetFullPath(options.Require("output"));
        ParallelOptions parallel = new() { CancellationToken = token };
        if (options.Bool("encoding"))
        {
            int encodingSize = CalibrationReferencePattern.PixelSize;
            byte[] encoding = CalibrationReferencePattern.ReadGrayPixels();
            CalibrationParameters parameters = target.Parameters;
            double inner2 = target.DrawingInnerRadiusMm * target.DrawingInnerRadiusMm;
            double outer2 = target.DrawingOuterRadiusMm * target.DrawingOuterRadiusMm;
            Parallel.For(0, encodingSize, parallel, y =>
            {
                for (int x = 0; x < encodingSize; x++)
                {
                    CalibrationPoint p = CalibrationReferencePattern.PixelToDisc(x, y, parameters.OuterRadiusMm, parameters.Kind);
                    double r2 = p.X * p.X + p.Y * p.Y;
                    if (r2 < inner2 - 1e-10 || r2 > outer2 + 1e-10) encoding[y * encodingSize + x] = 255;
                }
            });
            RasterCodec.SavePng(output, encodingSize, encodingSize, encoding, grayscale: true);
            return new { output, size = encodingSize };
        }

        int size = options.Int("size");
        double canvasRadius = options.Double("canvas", Math.Max(CalibrationReferencePattern.CanvasRadiusMm, target.Parameters.OuterRadiusMm));
        double inner = target.Parameters.InnerRadiusMm, outer = target.Parameters.OuterRadiusMm;
        byte[] pixels = new byte[checked(size * size)];
        double step = 2 * canvasRadius / size;
        Parallel.For(0, size, parallel, y =>
        {
            double ym = (y + 0.5) * step - canvasRadius;
            for (int x = 0; x < size; x++)
            {
                double xm = (x + 0.5) * step - canvasRadius;
                double r2 = xm * xm + ym * ym;
                pixels[y * size + x] = r2 >= inner * inner - 1e-10 && r2 <= outer * outer + 1e-10
                    ? BinaryGrayscale.Quantize(target.Sample(xm, ym))
                    : (byte)255;
            }
        });
        RasterCodec.SavePng(output, size, size, pixels, grayscale: true);
        return new { output, size };
    }

    private static object CalibrationGenerate(Options options, CancellationToken token)
    {
        CalibrationSession session = CalibrationSessionJson.Load(options.Require("session"));
        CalibrationTarget target = session.Target;
        CalibrationParameters p = target.Parameters;
        string path = Path.GetFullPath(options.Require("output"));
        string extension = Path.GetExtension(path).ToLowerInvariant();
        bool discImage = p.Kind is CalibrationDiscKind.Dvd or CalibrationDiscKind.BluRay;
        if (discImage ? extension != ".iso" : extension is not (".wav" or ".raw"))
            throw new ArgumentException("Choose an .iso output for DVD or BD, or a .wav or .raw output for CD.");

        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        // Generated in a sibling folder so a cancelled or failed job can't damage an earlier
        // output, and the disc image and its calibration record appear together.
        string staging = Path.Combine(directory, $".calibration-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        try
        {
            string staged = Path.Combine(staging, Path.GetFileName(path));
            switch (p.Kind)
            {
                case CalibrationDiscKind.Cd:
                    CdTrackGenerator.GeneratePattern(target.Sample, staged,
                        new CdDiscParameters(p.InnerRadiusMm, p.OuterRadiusMm, p.Sectors, p.LinearDensity, 0, p.OuterRadiusMm),
                        session.CdInterleave, cancellationToken: token);
                    break;
                case CalibrationDiscKind.BluRay:
                {
                    BluRayDiscParameters disc = new(checked((uint)p.Sectors), 1, p.InnerRadiusMm, p.OuterRadiusMm);
                    disc.Validate();
                    uint start = checked((uint)p.DrawingStartSector);
                    uint end = p.DrawingEndSectorExclusive == 0 ? disc.TotalSectors : checked((uint)p.DrawingEndSectorExclusive);
                    using FileStream output = new(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    BluRayStreamingGenerator.GenerateToStream(output, new BluRayStreamingOptions(disc, 0, disc.TotalSectors),
                        new BluRayPatternRangeMapping(disc, target.Sample, start, end, p.BluRayInvertMapping, allowParallelSampling: true),
                        progress: null, cancellationToken: token);
                    break;
                }
                default:
                {
                    using FileStream output = new(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    DvdStreamingGenerator.GeneratePattern(target.Sample, output,
                        new DvdStreamingOptions(checked((uint)p.Sectors), p.InnerRadiusMm, p.OuterRadiusMm, p.LinearDensity, 0,
                            PitchLinear: p.PitchLinear, PitchQuadratic: p.PitchQuadratic, PitchCubic: p.PitchCubic),
                        cancellationToken: token);
                    break;
                }
            }
            token.ThrowIfCancellationRequested();
            string sessionFile = Path.ChangeExtension(staged, ".calibration.json");
            CalibrationSessionJson.Save(sessionFile, session);
            foreach (string file in Directory.GetFiles(staging))
                File.Move(file, Path.Combine(directory, Path.GetFileName(file)), overwrite: true);
            return new { output = path, sessionPath = Path.ChangeExtension(path, ".calibration.json") };
        }
        finally
        {
            Directory.Delete(staging, recursive: true);
        }
    }

    /// <summary>Fits the traces saved in the session. Auto mode widens the radius box a step
    /// at a time until the optimum is interior, because a boundary-clamped answer is not a
    /// measurement. Mirrors the Windows calibration page's search.</summary>
    private static object CalibrationFit(Options options, CancellationToken token)
    {
        CalibrationSession session = CalibrationSessionJson.Load(options.Require("session"));
        CalibrationTarget target = session.Target;
        IReadOnlyList<CalibrationCrossTrace> traces = session.Photo?.Traces ?? [];
        bool auto = options.Bool("auto", session.FitOptions?.AutoRange ?? true);
        CalibrationFitOptions fitOptions = FitOptions(session,
            options.Double("range", session.FitOptions?.RadiusRangeMm ?? 0.02), auto,
            options.Bool("fit-dvd-pitch", session.FitOptions?.FitDvdPitch ?? true));

        (CalibrationFitResult result, double rangeMm) = auto
            ? FitWithAutoRange(target, traces, fitOptions, token)
            : (CalibrationCrossFitter.Fit(target, traces, fitOptions, token), fitOptions.RadiusRangeMm);

        CalibrationPoint[] points = traces.SelectMany(t => t.Points).ToArray();
        double[] radii = points.Select(p => Math.Sqrt(p.X * p.X + p.Y * p.Y)).ToArray();
        bool canOutline = radii.Length >= 2 && radii.Max() > radii.Min();
        var candidates = result.Candidates.Select(c =>
        {
            // A poor candidate can wind too tightly to trace. That rules out this candidate,
            // and the others are still worth showing.
            IReadOnlyList<CalibrationPoint> outline = [];
            string? outlineError = null;
            if (canOutline)
            {
                try
                {
                    outline = CalibrationCrossPrediction.GetOutline(target, c.Parameters, radii.Min(), radii.Max(),
                        c.RotationRadians, cancellationToken: token);
                }
                catch (Exception error) when (error is InvalidOperationException or ArgumentException)
                {
                    outlineError = error.Message;
                }
            }
            // A point beyond a small multiple of the mean residual is visibly off the curve.
            double threshold = Math.Max(0.2, c.RmsErrorMm * 2.5);
            return new
            {
                parameters = c.Parameters,
                rotationRadians = c.RotationRadians,
                rmsErrorMm = c.RmsErrorMm,
                maxErrorMm = c.MaxErrorMm,
                outlierCount = c.OutlierCount,
                accepted = outlineError is null && double.IsFinite(c.RmsErrorMm) && double.IsFinite(c.MaxErrorMm)
                    && c.RmsErrorMm <= MaxAcceptedRmsMm && c.MaxErrorMm <= MaxAcceptedPointErrorMm,
                outline,
                outlineError,
                outlierPointIndices = outline.Count < 2 ? [] : Enumerable.Range(0, points.Length)
                    .Where(i => DistanceToPolyline(points[i], outline) > threshold).ToArray(),
            };
        }).ToArray();
        return new
        {
            succeeded = result.Succeeded,
            boundaryLimited = result.BoundaryLimited,
            rangeMm,
            rangeExpanded = rangeMm > fitOptions.RadiusRangeMm,
            warnings = result.Warnings,
            candidates,
        };
    }

    private static (CalibrationFitResult, double) FitWithAutoRange(CalibrationTarget target,
        IReadOnlyList<CalibrationCrossTrace> traces, CalibrationFitOptions options, CancellationToken token)
    {
        CalibrationFitResult? best = null, last = null;
        double bestRange = options.RadiusRangeMm;
        double[] ranges = [options.RadiusRangeMm, 0.1, 0.5, 2, 5];
        foreach (double range in ranges.Where(r => r >= options.RadiusRangeMm).Distinct().OrderBy(r => r))
        {
            token.ThrowIfCancellationRequested();
            CalibrationFitResult result = CalibrationCrossFitter.Fit(target, traces, options with { RadiusRangeMm = range }, token);
            last = result;
            // BD's observed curve continues beyond the drawing band, so a narrow box can return
            // an interior solution with a visibly unusable residual. Keep widening past it.
            bool unusableBluRay = target.Parameters.Kind == CalibrationDiscKind.BluRay && result.RmsErrorMm > MaxAcceptedPointErrorMm;
            if (result.Succeeded && !result.BoundaryLimited && !unusableBluRay) return (result, range);
            if (result.Succeeded && (best is null || result.RmsErrorMm < best.RmsErrorMm))
            {
                best = result;
                bestRange = range;
            }
            if (!result.Succeeded && IsInputFailure(result)) break;
        }
        return (best ?? last ?? CalibrationCrossFitter.Fit(target, traces, options, token), bestRange);
    }

    // These match the fitter's messages: bad input, which no wider search can rescue.
    private static bool IsInputFailure(CalibrationFitResult result) => result.Warnings.Any(w =>
        w.Contains("至少标出", StringComparison.Ordinal)
        || w.Contains("覆盖范围太窄", StringComparison.Ordinal)
        || w.Contains("向内回退", StringComparison.Ordinal)
        || w.Contains("接近半圈", StringComparison.Ordinal)
        || w.Contains("转角过大", StringComparison.Ordinal));

    private static double DistanceToPolyline(CalibrationPoint point, IReadOnlyList<CalibrationPoint> line)
    {
        double best = double.PositiveInfinity;
        for (int i = 1; i < line.Count; i++)
        {
            double ax = line[i - 1].X, ay = line[i - 1].Y;
            double dx = line[i].X - ax, dy = line[i].Y - ay;
            double t = Math.Clamp(((point.X - ax) * dx + (point.Y - ay) * dy) / Math.Max(1e-30, dx * dx + dy * dy), 0, 1);
            double ex = point.X - ax - t * dx, ey = point.Y - ay - t * dy;
            best = Math.Min(best, ex * ex + ey * ey);
        }
        return Math.Sqrt(best);
    }

    /// <summary>Fits the disc outline in a photo and writes the perspective-corrected image.
    /// The caller has already bounded the photo's size.</summary>
    private static object PhotoRectify(Options options, CancellationToken token)
    {
        PhotoRequest request = JsonSerializer.Deserialize<PhotoRequest>(File.ReadAllText(options.Require("request")), Json)
            ?? throw new ArgumentException("The photo request is empty.");
        CalibrationPhotoFitResult fit = CalibrationPhotoRectifier.Fit(request.Outer, request.Hole,
            request.PhysicalOuterRadiusMm, PhysicalHoleRadiusMm, token);
        if (!fit.Succeeded || fit.Transform is null)
            return new { succeeded = false, message = fit.Message, outerRmsPixels = fit.OuterRmsPixels, holeRmsPixels = fit.HoleRmsPixels };

        double canvasRadius = request.PhysicalOuterRadiusMm + 3;
        if (!fit.Transform.IsValidForDisc(canvasRadius))
            throw new ArgumentException("The photo transform degenerates inside the canvas. Adjust the outline points.");
        BgraRaster source = RasterCodec.LoadBgra32(options.Require("input"));
        int pixelSize = options.Int("size", RectifiedPhotoSize);
        byte[] pixels = Rectify(source, fit.Transform.DiscToSourceMatrix9, canvasRadius, pixelSize, token);
        string output = Path.GetFullPath(options.Require("output"));
        RasterCodec.SavePng(output, pixelSize, pixelSize, pixels, grayscale: false);
        return new
        {
            succeeded = true,
            message = fit.Message,
            outerRmsPixels = fit.OuterRmsPixels,
            holeRmsPixels = fit.HoleRmsPixels,
            output,
            canvasRadiusMm = canvasRadius,
            pixelSize,
        };
    }

    private static byte[] Rectify(BgraRaster image, double[] matrix, double canvasRadius, int pixelSize, CancellationToken token)
    {
        int width = image.Width, height = image.Height;
        int sourceStride = width * 4, stride = checked(pixelSize * 4);
        byte[] source = image.Pixels;
        byte[] pixels = new byte[checked(stride * pixelSize)];
        double step = 2 * canvasRadius / pixelSize;
        Parallel.For(0, pixelSize, new ParallelOptions { CancellationToken = token }, y =>
        {
            double ym = (y + 0.5) * step - canvasRadius;
            for (int x = 0; x < pixelSize; x++)
            {
                double xm = (x + 0.5) * step - canvasRadius;
                double divisor = matrix[6] * xm + matrix[7] * ym + matrix[8];
                int destination = y * stride + x * 4;
                double sx = (matrix[0] * xm + matrix[1] * ym + matrix[2]) / divisor;
                double sy = (matrix[3] * xm + matrix[4] * ym + matrix[5]) / divisor;
                if (xm * xm + ym * ym > canvasRadius * canvasRadius
                    || !double.IsFinite(sx) || !double.IsFinite(sy) || sx < 0 || sy < 0 || sx > width - 1 || sy > height - 1)
                {
                    pixels[destination] = pixels[destination + 1] = pixels[destination + 2] = pixels[destination + 3] = 255;
                    continue;
                }
                int x0 = (int)Math.Floor(sx), y0 = (int)Math.Floor(sy);
                int x1 = Math.Min(x0 + 1, width - 1), y1 = Math.Min(y0 + 1, height - 1);
                double fx = sx - x0, fy = sy - y0;
                for (int channel = 0; channel < 4; channel++)
                {
                    double value = source[y0 * sourceStride + x0 * 4 + channel] * (1 - fx) * (1 - fy)
                        + source[y0 * sourceStride + x1 * 4 + channel] * fx * (1 - fy)
                        + source[y1 * sourceStride + x0 * 4 + channel] * (1 - fx) * fy
                        + source[y1 * sourceStride + x1 * 4 + channel] * fx * fy;
                    pixels[destination + channel] = (byte)Math.Clamp((int)Math.Round(value), 0, 255);
                }
            }
        });
        token.ThrowIfCancellationRequested();
        return pixels;
    }

    // ---- Option helpers ----

    private static BluRayDiscParameters BluRayDisc(Options options, string innerKey, string outerKey)
    {
        long sectors = options.Long("total-sectors");
        if (sectors > uint.MaxValue) throw new ArgumentOutOfRangeException(nameof(sectors), "Too many sectors for the BD engine.");
        BluRayDiscParameters disc = new((uint)sectors, 1, options.Double(innerKey), options.Double(outerKey));
        disc.Validate();
        return disc;
    }

    private static DvdStreamingOptions DvdOptions(Options options, string innerKey = "r0", string outerKey = "r1", string pitchKey = "pitch")
    {
        long sectors = options.Long("total-sectors");
        if (sectors > uint.MaxValue) throw new ArgumentOutOfRangeException(nameof(sectors), "Too many sectors for the DVD engine.");
        DvdStreamingOptions disc = new((uint)sectors, options.Double(innerKey), options.Double(outerKey),
            PitchLinear: options.Double($"{pitchKey}-linear", 0),
            PitchQuadratic: options.Double($"{pitchKey}-quadratic", 0),
            PitchCubic: options.Double($"{pitchKey}-cubic", 0));
        disc.Validate();
        return disc;
    }

    private static ToneProfile Tone(Options options) => new(
        options.Double("tone-dither", 0),
        options.Int("tone-levels", ToneProfile.TwoLevels),
        options.Double("tone-brightness", 0),
        options.Bool("tone-gamma"));

    private sealed record SaveRequest(CalibrationPhotoSession? Photo, double RadiusRangeMm, bool AutoRange, bool FitDvdPitch);

    private sealed record PhotoRequest(IReadOnlyList<CalibrationPoint> Outer, IReadOnlyList<CalibrationPoint> Hole, double PhysicalOuterRadiusMm);

    private sealed class Options
    {
        private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

        internal Options(IEnumerable<string> arguments)
        {
            string? key = null;
            foreach (string argument in arguments)
            {
                if (key is not null)
                {
                    _values[key] = argument;
                    key = null;
                }
                else if (argument.StartsWith("--", StringComparison.Ordinal))
                {
                    key = argument[2..];
                }
                else
                {
                    throw new ArgumentException($"Unexpected argument '{argument}'.");
                }
            }
            if (key is not null) throw new ArgumentException($"Option --{key} needs a value.");
        }

        internal string? Optional(string key)
            => _values.TryGetValue(key, out string? value) && !string.IsNullOrWhiteSpace(value) ? value : null;

        internal string Require(string key) => Optional(key) ?? throw new ArgumentException($"Missing option --{key}.");

        internal double Double(string key, double? fallback = null)
            => Optional(key) is { } value
                ? double.Parse(value, NumberStyles.Float, CultureInfo.InvariantCulture)
                : fallback ?? throw new ArgumentException($"Missing option --{key}.");

        internal long Long(string key, long? fallback = null)
            => Optional(key) is { } value
                ? long.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture)
                : fallback ?? throw new ArgumentException($"Missing option --{key}.");

        internal int Int(string key, int? fallback = null)
            => Optional(key) is { } value
                ? int.Parse(value, NumberStyles.Integer, CultureInfo.InvariantCulture)
                : fallback ?? throw new ArgumentException($"Missing option --{key}.");

        internal bool Bool(string key, bool fallback = false)
            => Optional(key) is { } value ? bool.Parse(value) : fallback;

        internal long Long(string key) => Long(key, null);
    }
}
