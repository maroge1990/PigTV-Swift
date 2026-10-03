#!/bin/zsh
# Offline bright moving video with two real audio tracks and subtitles.
set -eu
mkdir -p /private/tmp/pig-deep-media
cat > /private/tmp/pig-deep-media/captions.srt <<'EOF'
1
00:00:00,000 --> 00:01:59,000
Local subtitle fixture - PigTV player review
EOF
ffmpeg -y -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=120' -f lavfi -i 'anullsrc=r=48000:cl=stereo' -f lavfi -i 'anullsrc=r=48000:cl=stereo' -i /private/tmp/pig-deep-media/captions.srt -map 0:v -map 1:a -map 2:a -map 3:s -t 120 -c:v libx264 -preset ultrafast -crf 28 -c:a aac -c:s mov_text -metadata:s:a:0 language=eng -metadata:s:a:1 language=fra -metadata:s:s:0 language=eng -movflags +faststart /private/tmp/pig-deep-media/review.mp4
