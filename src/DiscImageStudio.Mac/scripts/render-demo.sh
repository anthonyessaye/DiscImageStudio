#!/bin/bash
# Renders the demo video and README stills from the app's real pages and the real engine.
# Nothing appears on screen: the pages are drawn into an off-screen window. It needs about
# 2 GB of free space while running, and ffmpeg. Output goes to docs/media/.
set -euo pipefail

mac_dir="$(cd "$(dirname "$0")/.." && pwd)"
cli="$mac_dir/dist/Disc Image Studio.app/Contents/Resources/cli/disc-image-studio"
media="$mac_dir/docs/media"
frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
[[ -x "$cli" ]] || "$mac_dir/scripts/build-app.sh"

echo "==> Rendering frames (this generates a full 80-minute CD track, then deletes it)"
(cd "$mac_dir" && DISC_IMAGE_STUDIO_CLI="$cli" DISC_IMAGE_STUDIO_DEMO_FRAMES="$frames" \
  DISC_IMAGE_STUDIO_ROOT="$(cd "$mac_dir/../.." && pwd)" swift test --filter DemoVideoTests)

mkdir -p "$media"
echo "==> Encoding"
(cd "$frames" && ffmpeg -y -loglevel error -f concat -safe 0 -i frames.txt \
  -vf "scale=1600:-2:flags=lanczos,fps=30,format=yuv420p" \
  -c:v libx264 -preset slow -crf 25 -movflags +faststart "$media/demo.mp4")

# GitHub won't play a repository MP4 inline in a README, so a short GIF shows the design step there.
(cd "$frames" && ffmpeg -y -loglevel error -f concat -safe 0 -i gif.txt \
  -filter_complex "fps=10,scale=800:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  "$media/demo.gif")

for still in "$frames"/still-*.png; do
  name="$(basename "$still" .png)"
  sips -Z 1400 "$still" --out "$media/${name#still-}.png" >/dev/null
done
ls -lh "$media"
