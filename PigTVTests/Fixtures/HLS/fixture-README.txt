Generated for the real-playback harness (PigTVTests/RealPlaybackTests.swift):
ffmpeg -f lavfi -i "testsrc2=size=320x180:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 6 \
  -c:v libx264 -profile:v main -pix_fmt yuv420p -b:v 300k -g 50 -keyint_min 50 -sc_threshold 0 -c:a aac -b:a 64k -ac 2 \
  -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_fmp4_init_filename fixture-init.mp4 \
  -hls_segment_filename "fixture-seg%d.m4s" stream.m3u8
master.m3u8 mirrors the server's buildMasterPlaylist (FRAME-RATE, VIDEO-RANGE=SDR, one variant: stream.m3u8).
