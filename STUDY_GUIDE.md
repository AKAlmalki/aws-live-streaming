# Streaming Interview Study Guide

## SRT vs WebRTC vs RTMP

### SRT

- Designed for reliable contribution over unmanaged networks.
- Uses ARQ/retransmission and encryption; works well for encoder-to-cloud ingest.
- Typical latency is low to medium (often seconds range), with good stability.

### WebRTC

- Designed for ultra-low-latency interactive media (sub-second targets).
- Best for real-time conferencing, interactivity, and bidirectional experiences.
- More complex at scale due to signaling, NAT traversal, and media server design.

### RTMP

- Legacy ingest protocol still common for encoder compatibility.
- Stable and easy to use, but generally higher latency and aging ecosystem.
- Commonly converted into HLS/DASH for playback.

## HLS vs LL-HLS vs DASH

### HLS

- Segment-based HTTP streaming with broad device/CDN support.
- Standard latency is often several seconds to tens of seconds.
- Operationally simple and robust at scale.

### LL-HLS

- Extends HLS with partial segments/chunks and faster playlist updates.
- Reduces end-to-end latency while keeping HLS compatibility model.
- Requires careful CDN/cache tuning and player support.

### DASH

- Open standard adaptive HTTP streaming (MPD manifests).
- Strong in Android/OTT ecosystems; often paired with CMAF.
- Latency depends on segment/chunk strategy and player implementation.

## Benefits of CMAF

- Single fragmented MP4 media format reusable across HLS and DASH workflows.
- Reduces duplicate packaging/transcoding complexity.
- Improves cache efficiency and simplifies multi-protocol delivery.
- Enables low-latency chunked workflows in modern players/CDNs.

## Strategies to Reduce Latency

- Use smaller GOP sizes (for example 1-2 seconds) to align keyframe cadence.
- Use shorter segment durations and partial segment/chunk transfer.
- Enable chunked transfer and low-latency packaging mode where supported.
- Separate cache behavior for manifests (very short TTL) vs segments (longer TTL).
- Reduce pipeline buffering at encoder, packager, and player.
- Choose protocols by use case: WebRTC for interactive, LL-HLS for scalable low-latency broadcast.

## Applying LL-HLS to this Terraform project

This repo now uses two separate stacks to avoid breaking the original working HLS pipeline:

- `terraform-hls`: MediaPackage v1 standard HLS pipeline.
- `terraform-ll-hls`: MediaPackage v2 + LL-HLS pipeline (MediaLive channel is provisioned through CloudFormation to support MediaPackage v2 destination settings).

Both stacks are intentionally configured in **`eu-west-2` / `eu-west-2a`** to keep comparisons fair. If HLS runs in London and LL-HLS runs in UAE, region distance can bias latency results.

For LL-HLS stability, you also need:

- CloudFront behavior that forwards query strings for playlist/part requests (LL-HLS URLs often include `_HLS_msn` and `_HLS_part`).
- A player that supports LL-HLS playlist extensions/partial segments. The project’s Hls.js player supports this via the LL-HLS mode toggle.
