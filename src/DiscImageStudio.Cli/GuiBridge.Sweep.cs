using DiscImageStudio.Core;
using DiscImageStudio.Dvd;
using DiscImageStudio.ImageIO;

namespace DiscImageStudio.Cli;

/// <summary>A calibration target for discs too far from any known geometry to show the normal
/// target's arms. An error of about 0.02 mm winds those thin arms round the disc until they
/// vanish, leaving nothing to trace.
///
/// This target draws a half-black, half-white disc, under an assumption about the number of
/// turns per sector that changes smoothly with radius. It is wrong almost everywhere, which
/// winds the pattern into a spiral too fine to see. But the assumption sweeps across the
/// plausible range, so at one radius it matches the real disc, and there the pattern unwinds
/// into a broad, slow band that survives a soft photo. That radius is the measurement. Two
/// such chirps, sweeping opposite ways, measure the disc at two radii, which is enough to
/// solve for its inner and outer radius, close enough that the normal target's arms show.
///
/// Stepped bands, tried first, failed on soft photos: only the one or two nearest the true
/// value wound slowly enough to survive blur, too few to read safely.</summary>
internal static partial class GuiBridge
{
    private const double ChannelBitLengthMm = 133.3e-6;
    private const int ChannelBitsPerSector = 38688;

    /// <summary>The assumed turns-per-sector error sweeps through this range, as a fraction.
    /// The measured DVD presets span about +/-0.35%, and the DVD format allows up to about 1%
    /// in channel bit length.</summary>
    private const double ChirpLowError = -0.008, ChirpHighError = 0.008;

    private sealed record Chirp(int Index, double StartMm, double EndMm, double StartError, double EndError)
    {
        internal double Slope => (EndError - StartError) / (EndMm - StartMm);
        internal double ErrorAt(double radius) => StartError + Slope * (radius - StartMm);
    }

    private sealed class ChirpTarget
    {
        internal DvdTrackGeometry Geometry { get; }
        internal double InnerMm { get; }
        internal double OuterMm { get; }
        internal long Sectors { get; }
        internal double LengthMm => Sectors * (double)ChannelBitsPerSector * ChannelBitLengthMm;
        internal double Growth => Geometry.RadialGrowthPerRadianMm;

        // Black marker rings sit at fixed sectors, so they stay rings on any disc. Finding them
        // in the photo ties its radii to sectors, without trusting the photo's overall scale.
        internal const double RingMm = 0.5;
        internal const double LastRingStartMm = 56.5;
        internal static readonly double[] RingCentresMm = [25.25, 41.25, 56.75];

        internal Chirp[] Chirps { get; } =
        [
            new(0, 25.0, 41.0, ChirpLowError, ChirpHighError),
            new(1, 41.0, LastRingStartMm, ChirpHighError, ChirpLowError),
        ];

        internal ChirpTarget(double inner, double outer, long sectors)
        {
            InnerMm = inner;
            OuterMm = outer;
            Sectors = sectors;
            Geometry = DvdTrackGeometry.Create(inner, outer, sectors * (double)ChannelBitsPerSector * ChannelBitLengthMm);
        }

        internal Chirp? ChirpAt(double radius) => Array.Find(Chirps, c => radius >= c.StartMm && radius < c.EndMm);

        /// <summary>The extra angle this chirp adds at a radius: the assumed error, integrated
        /// over the track angle from the chirp's start.</summary>
        internal double ExtraAngle(Chirp chirp, double radius)
        {
            double d = radius - chirp.StartMm;
            return (chirp.StartError * d + chirp.Slope * d * d / 2) / Growth;
        }

        /// <summary>y runs down, as the generator passes it. At a position on the assumed spiral
        /// the polar angle equals the track angle.</summary>
        internal byte Sample(double x, double y)
        {
            double radius = Math.Sqrt(x * x + y * y);
            if (radius >= LastRingStartMm && radius < LastRingStartMm + RingMm) return 0;
            if (ChirpAt(radius) is not { } chirp) return 255;
            if (radius < chirp.StartMm + RingMm) return 0;
            return Math.Sin(Math.Atan2(y, x) + ExtraAngle(chirp, radius)) >= 0 ? (byte)0 : (byte)255;
        }

        /// <summary>The photo radii worth reading: inside a chirp and clear of its rings.</summary>
        internal IEnumerable<double> ReadRadii(Chirp chirp, double step)
        {
            for (double r = chirp.StartMm + RingMm + 0.1; r <= chirp.EndMm - 0.1; r += step) yield return r;
        }
    }

    private static ChirpTarget SweepFromOptions(Options options)
        => new(options.Double("r0", 24), options.Double("r1", 58), options.Long("total-sectors", 2_295_104));

    /// <summary>Writes the target as an ISO, staged so a cancelled job leaves nothing behind.</summary>
    private static object SweepGenerate(Options options, CancellationToken token)
    {
        ChirpTarget target = SweepFromOptions(options);
        string path = Path.GetFullPath(options.Require("output"));
        if (!path.EndsWith(".iso", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Choose an .iso output.");
        string staged = path + ".partial";
        DvdStreamingOptions disc = new((uint)target.Sectors, target.InnerMm, target.OuterMm);
        disc.Validate();
        try
        {
            using (FileStream stream = new(staged, FileMode.Create, FileAccess.Write, FileShare.None))
                DvdStreamingGenerator.GeneratePattern(target.Sample, stream, disc, cancellationToken: token);
            token.ThrowIfCancellationRequested();
            File.Move(staged, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(staged)) File.Delete(staged);
        }
        return new { output = path, sectors = target.Sectors };
    }

    /// <summary>Renders what the target would look like on a disc with the given real geometry,
    /// in the same coordinates as a corrected photo. Forward model only: it does not decode an
    /// ISO, which the engine's own `simulate` command does.</summary>
    private static object SweepSimulate(Options options, CancellationToken token)
    {
        ChirpTarget target = SweepFromOptions(options);
        int size = options.Int("size", 1400);
        double canvas = options.Double("canvas", 63);
        double length = target.LengthMm;
        DvdTrackGeometry actual = DvdTrackGeometry.Create(options.Double("actual-r0"), options.Double("actual-r1"), length,
            options.Double("actual-pitch-linear", 0), options.Double("actual-pitch-quadratic", 0), options.Double("actual-pitch-cubic", 0));
        double rotation = options.Double("rotation", 0) * Math.PI / 180;
        long samples = target.Sectors * options.Int("samples-per-sector", 8);
        long[] sum = new long[size * size];
        int[] count = new int[size * size];
        object gate = new();
        double pixelsPerMm = size / (2 * canvas);
        double centre = (size - 1) / 2.0;
        Parallel.For(0, 256, new ParallelOptions { CancellationToken = token }, chunk =>
        {
            long[] localSum = new long[size * size];
            int[] localCount = new int[size * size];
            long first = samples * chunk / 256, last = samples * (chunk + 1) / 256;
            for (long i = first; i < last; i++)
            {
                double arc = length * (i + 0.5) / samples;
                (double generatedRadius, double generatedAngle) = target.Geometry.AtArcLengthFast(arc);
                byte value = target.Sample(generatedRadius * Math.Cos(generatedAngle), generatedRadius * Math.Sin(generatedAngle));
                (double radius, double angle) = actual.AtArcLengthFast(arc);
                int x = (int)Math.Round(centre + radius * pixelsPerMm * Math.Cos(angle + rotation));
                int y = (int)Math.Round(centre + radius * pixelsPerMm * Math.Sin(angle + rotation));
                if (x < 0 || y < 0 || x >= size || y >= size) continue;
                localSum[y * size + x] += value;
                localCount[y * size + x]++;
            }
            lock (gate)
            {
                for (int p = 0; p < sum.Length; p++)
                {
                    sum[p] += localSum[p];
                    count[p] += localCount[p];
                }
            }
        });
        byte[] pixels = new byte[size * size];
        for (int p = 0; p < pixels.Length; p++) pixels[p] = count[p] == 0 ? (byte)128 : (byte)(sum[p] / count[p]);
        string output = Path.GetFullPath(options.Require("output"));
        RasterCodec.SavePng(output, size, size, pixels, grayscale: true);
        return new { output };
    }

    private const int ChirpAngles = 720;
    private const double ChirpRadialStepMm = 0.04;
    private const double ChirpHighPassMm = 1.5;
    private const double ChirpWindowMm = 2.5;

    /// <summary>Solves for the disc's real radii from a perspective-corrected photo, or reports
    /// no answer. A wrong answer here wastes a disc, so it must not guess.</summary>
    private static object SweepRead(Options options, CancellationToken token)
    {
        ChirpTarget target = SweepFromOptions(options);
        BgraRaster raster = RasterCodec.LoadBgra32(options.Require("input"));
        if (raster.Width != raster.Height) throw new ArgumentException("A corrected photo must be square.");
        int size = raster.Width;
        double canvas = options.Double("canvas", 63);
        double[] gray = new double[size * size];
        for (int p = 0; p < gray.Length; p++)
            gray[p] = 0.0722 * raster.Pixels[p * 4] + 0.7152 * raster.Pixels[p * 4 + 1] + 0.2126 * raster.Pixels[p * 4 + 2];
        double pixelsPerMm = size / (2 * canvas);
        double middle = (size - 1) / 2.0;

        double Pixel(double x, double y)
        {
            int xi = (int)x, yi = (int)y;
            if (xi < 0 || yi < 0 || xi >= size - 1 || yi >= size - 1) return double.NaN;
            double fx = x - xi, fy = y - yi;
            return gray[yi * size + xi] * (1 - fx) * (1 - fy) + gray[yi * size + xi + 1] * fx * (1 - fy)
                + gray[(yi + 1) * size + xi] * (1 - fx) * fy + gray[(yi + 1) * size + xi + 1] * fx * fy;
        }

        double[][] radii = target.Chirps.Select(c => target.ReadRadii(c, ChirpRadialStepMm).ToArray()).ToArray();
        int highPassReach = (int)Math.Round(ChirpHighPassMm / ChirpRadialStepMm);

        // For one disc centre: at each radius, the half-disc pattern's strength and phase.
        (double[] Re, double[] Im)[] Demodulate(double offsetXmm, double offsetYmm)
        {
            double cx = middle + offsetXmm * pixelsPerMm, cy = middle + offsetYmm * pixelsPerMm;
            var result = new (double[] Re, double[] Im)[target.Chirps.Length];
            for (int c = 0; c < target.Chirps.Length; c++)
            {
                double[] rs = radii[c];
                double[] re = new double[rs.Length], im = new double[rs.Length];
                object gate = new();
                Parallel.For(0, ChirpAngles, new ParallelOptions { CancellationToken = token },
                    () => (new double[rs.Length], new double[rs.Length]),
                    (a, _, local) =>
                    {
                        double theta = 2 * Math.PI * a / ChirpAngles;
                        double ca = Math.Cos(theta), sa = Math.Sin(theta);
                        double[] line = new double[rs.Length], prefix = new double[rs.Length + 1];
                        for (int i = 0; i < rs.Length; i++)
                        {
                            line[i] = Pixel(cx + rs[i] * pixelsPerMm * ca, cy + rs[i] * pixelsPerMm * sa);
                            if (double.IsNaN(line[i])) return local;
                            prefix[i + 1] = prefix[i] + line[i];
                        }
                        for (int i = 0; i < rs.Length; i++)
                        {
                            // Reflections change slowly along a radius, and the pattern doesn't.
                            int low = Math.Max(0, i - highPassReach), high = Math.Min(rs.Length, i + highPassReach + 1);
                            double trend = (prefix[high] - prefix[low]) / (high - low);
                            // Limiting each value keeps bright streaks from outvoting everything else.
                            double v = Math.Clamp(line[i] - trend, -12, 12);
                            local.Item1[i] += v * ca;
                            local.Item2[i] -= v * sa;
                        }
                        return local;
                    },
                    local =>
                    {
                        lock (gate)
                        {
                            for (int i = 0; i < rs.Length; i++)
                            {
                                re[i] += local.Item1[i];
                                im[i] += local.Item2[i];
                            }
                        }
                    });
                result[c] = (re, im);
            }
            return result;
        }

        // How well a chirp's pattern focuses if the disc matches at radius `at`. Everywhere else
        // the known chirp shape cancels out, which is what makes this so hard to fool.
        double Focus(Chirp chirp, double[] rs, double[] re, double[] im, double at, int sign)
        {
            double rate = sign * Math.PI * chirp.Slope / target.Geometry.TrackPitchMm;
            double x = 0, y = 0;
            int first = Math.Max(0, (int)Math.Ceiling((at - ChirpWindowMm - rs[0]) / ChirpRadialStepMm));
            int last = Math.Min(rs.Length - 1, (int)Math.Floor((at + ChirpWindowMm - rs[0]) / ChirpRadialStepMm));
            for (int i = first; i <= last; i++)
            {
                double d = rs[i] - at;
                double phase = -rate * d * d;
                double cp = Math.Cos(phase), sp = Math.Sin(phase);
                x += re[i] * cp - im[i] * sp;
                y += re[i] * sp + im[i] * cp;
            }
            return Math.Sqrt(x * x + y * y);
        }

        // For one chirp: the radius that focuses best, and how far it stands out.
        (double Radius, double Contrast, double Value) BestFocus(int c, (double[] Re, double[] Im) z, int sign)
        {
            Chirp chirp = target.Chirps[c];
            double[] rs = radii[c];
            List<double> values = [];
            double best = 0, bestAt = rs[0];
            for (double at = rs[0] + 1.0; at <= rs[^1] - 1.0; at += 0.02)
            {
                double v = Focus(chirp, rs, z.Re, z.Im, at, sign);
                values.Add(v);
                if (v > best) { best = v; bestAt = at; }
            }
            values.Sort();
            double median = values[values.Count / 2];
            return (bestAt, median > 0 ? best / median : 0, best);
        }

        // The photo correction leaves the centre a little off, and even 0.5 mm scrambles a
        // fine spiral, so try nearby centres and keep the one that focuses best.
        (double X, double Y, int Sign, double Score) bestCentre = (0, 0, 1, double.NegativeInfinity);
        void TryCentre(double x, double y)
        {
            var z = Demodulate(x, y);
            foreach (int sign in new[] { 1, -1 })
            {
                double score = 0;
                for (int c = 0; c < z.Length; c++) score += Math.Log(BestFocus(c, z[c], sign).Contrast + 1e-9);
                if (score > bestCentre.Score) bestCentre = (x, y, sign, score);
            }
        }
        double reach = options.Double("centre-search", 1.0);
        for (double y = -reach; y <= reach + 1e-9; y += 0.25)
            for (double x = -reach; x <= reach + 1e-9; x += 0.25)
                TryCentre(x, y);
        (double startX, double startY) = (bestCentre.X, bestCentre.Y);
        for (double y = startY - 0.2; y <= startY + 0.2 + 1e-9; y += 0.05)
            for (double x = startX - 0.2; x <= startX + 0.2 + 1e-9; x += 0.05)
                TryCentre(x, y);

        var demodulated = Demodulate(bestCentre.X, bestCentre.Y);
        var focused = Enumerable.Range(0, target.Chirps.Length).Select(c => BestFocus(c, demodulated[c], bestCentre.Sign)).ToArray();

        // Finds the marker rings in the photo, which maps its radii to sector positions. The
        // answer then rests on counting turns between known sectors, not on the photo's scale.
        double centreX = middle + bestCentre.X * pixelsPerMm, centreY = middle + bestCentre.Y * pixelsPerMm;
        double RingScore(double at)
        {
            double Average(double from, double to)
            {
                double total = 0;
                int count = 0;
                for (double r = from; r < to; r += 0.04)
                    for (int a = 0; a < ChirpAngles; a += 2)
                    {
                        double theta = 2 * Math.PI * a / ChirpAngles;
                        double v = Pixel(centreX + r * pixelsPerMm * Math.Cos(theta), centreY + r * pixelsPerMm * Math.Sin(theta));
                        if (double.IsNaN(v)) continue;
                        total += v;
                        count++;
                    }
                return count > 0 ? total / count : 0;
            }
            return Average(at - 0.25, at + 0.25) - (Average(at - 0.75, at - 0.25) + Average(at + 0.25, at + 0.75)) / 2;
        }
        double[] nominal = ChirpTarget.RingCentresMm;
        double[] found = new double[nominal.Length];
        double[] ringContrast = new double[nominal.Length];
        Parallel.For(0, nominal.Length, new ParallelOptions { CancellationToken = token }, m =>
        {
            List<(double At, double Score)> scan = [];
            // The corrected photo's scale is good to about 1.5%. Looking further out than that
            // finds the bright rim of the disc instead of the outer ring.
            for (double at = nominal[m] - 0.9; at <= nominal[m] + 0.9 + 1e-9; at += 0.02) scan.Add((at, RingScore(at)));
            double[] sizes = scan.Select(item => Math.Abs(item.Score)).OrderBy(v => v).ToArray();
            double background = sizes[sizes.Length / 2];
            var best = scan.MaxBy(item => Math.Abs(item.Score));
            found[m] = best.At;
            ringContrast[m] = background > 0 ? Math.Abs(best.Score) / background : 0;
        });
        double sx = found.Sum(), sy = nominal.Sum(), sxx = found.Sum(v => v * v);
        double sxy = found.Zip(nominal, (x, y) => x * y).Sum();
        double scale = (nominal.Length * sxy - sx * sy) / (nominal.Length * sxx - sx * sx);
        double shift = (sy - scale * sx) / nominal.Length;
        double ringResidual = found.Zip(nominal, (x, y) => Math.Abs(scale * x + shift - y)).Max();
        // Three rings on one straight line, at a sensible scale, are hard to get by accident.
        bool ringsFound = ringResidual <= 0.05 && Math.Abs(scale - 1) <= 0.025;
        double ToAssumed(double photoRadius) => ringsFound ? scale * photoRadius + shift : photoRadius;

        // Where a chirp focuses, its assumed error is the real one. Turns per sector go as
        // 1 / radius, which gives that sector's effective radius.
        double i2 = target.InnerMm * target.InnerMm, o2 = target.OuterMm * target.OuterMm;
        var points = focused.Select((f, c) =>
        {
            Chirp chirp = target.Chirps[c];
            double assumed = ToAssumed(f.Radius);
            double error = chirp.ErrorAt(assumed);
            return (T: (assumed * assumed - i2) / (o2 - i2), Actual: assumed / (1 + error), Error: error);
        }).ToArray();
        double range = (points[1].Actual * points[1].Actual - points[0].Actual * points[0].Actual) / (points[1].T - points[0].T);
        double start = points[0].Actual * points[0].Actual - range * points[0].T;
        bool solved = start > 0 && start + range > 0 && range > 0;
        double inner = solved ? Math.Sqrt(start) : double.NaN;
        double outer = solved ? Math.Sqrt(start + range) : double.NaN;

        // The focus points only use the middle of each peak. Now predict the pattern's exact
        // phase at every radius for a candidate pair of radii, and keep the pair it fits best.
        if (solved)
        {
            double length = target.LengthMm, assumedGrowth = target.Growth;
            double Coherence(double candidateInner, double candidateOuter)
            {
                double a2 = candidateInner * candidateInner, spanSquared = candidateOuter * candidateOuter - a2;
                double growth = spanSquared / (2 * length);
                double total = 0;
                for (int c = 0; c < target.Chirps.Length; c++)
                {
                    Chirp chirp = target.Chirps[c];
                    double[] rs = radii[c];
                    double x = 0, y = 0;
                    for (int i = 0; i < rs.Length; i++)
                    {
                        if (Math.Abs(rs[i] - focused[c].Radius) > ChirpWindowMm) continue;
                        double assumed = ToAssumed(rs[i]);
                        double t = (assumed * assumed - i2) / (o2 - i2);
                        double candidateRadius = Math.Sqrt(a2 + spanSquared * t);
                        double phase = bestCentre.Sign * ((assumed - target.InnerMm) / assumedGrowth
                            - (candidateRadius - candidateInner) / growth + target.ExtraAngle(chirp, assumed));
                        double cp = Math.Cos(phase), sp = Math.Sin(phase);
                        x += demodulated[c].Re[i] * cp + demodulated[c].Im[i] * sp;
                        y += demodulated[c].Im[i] * cp - demodulated[c].Re[i] * sp;
                    }
                    total += Math.Sqrt(x * x + y * y);
                }
                return total;
            }
            foreach ((double reachMm, double stepMm) in new[] { (0.04, 0.002), (0.004, 0.0002) })
            {
                double centreInner = inner, centreOuter = outer;
                object gate = new();
                double bestValue = double.NegativeInfinity;
                int steps = (int)Math.Round(reachMm / stepMm);
                Parallel.For(-steps, steps + 1, new ParallelOptions { CancellationToken = token }, a =>
                {
                    double i = centreInner + a * stepMm;
                    double localBest = double.NegativeInfinity, localOuter = centreOuter;
                    for (int b = -steps; b <= steps; b++)
                    {
                        double o = centreOuter + b * stepMm;
                        double v = Coherence(i, o);
                        if (v > localBest) { localBest = v; localOuter = o; }
                    }
                    lock (gate)
                    {
                        if (localBest > bestValue)
                        {
                            bestValue = localBest;
                            inner = i;
                            outer = localOuter;
                        }
                    }
                });
            }
        }

        // A disc's real radii are only a little from nominal. An answer far outside that says
        // the peaks aren't really the target.
        bool plausible = solved && Math.Abs(inner - target.InnerMm) <= 0.6 && Math.Abs(outer - target.OuterMm) <= 0.8;

        // On test photos with no sweep target the contrast never passed about 6, and on faint,
        // blurred simulated targets it stayed above 11.
        double minContrast = options.Double("min-contrast", 9);
        double weakest = focused.Min(f => f.Contrast);
        bool confident = plausible && ringsFound && weakest >= minContrast;
        return new
        {
            confident,
            innerRadiusMm = confident ? inner : (double?)null,
            outerRadiusMm = confident ? outer : (double?)null,
            bestGuess = new { innerRadiusMm = solved ? inner : (double?)null, outerRadiusMm = solved ? outer : (double?)null },
            contrast = focused.Select(f => f.Contrast).ToArray(),
            focusRadiusMm = focused.Select(f => f.Radius).ToArray(),
            measuredError = points.Select(p => p.Error).ToArray(),
            ringsFound,
            ringRadiusMm = found,
            ringContrast,
            photoScale = scale,
            ringResidualMm = ringResidual,
            mirrored = bestCentre.Sign < 0,
            centreOffsetMm = new { x = bestCentre.X, y = bestCentre.Y },
        };
    }
}
