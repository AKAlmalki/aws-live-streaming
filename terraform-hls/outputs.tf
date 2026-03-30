output "mediaconnect_flow_arn" {
  description = "ARN of the MediaConnect flow."
  value       = aws_cloudformation_stack.mediaconnect_flow.outputs["FlowArn"]
}

output "mediapackage_hls_origin_url" {
  description = "Direct MediaPackage endpoint URL."
  value       = aws_cloudformation_stack.mediapackage_hls_endpoint.outputs["HlsEndpointUrl"]
}

output "srt_ingest_url" {
  description = "OBS SRT URL for LISTENER mode. streamid in the URL is for the encoder (OBS); do not set StreamId on the MediaConnect SRT Listener source in Terraform."
  value = upper(var.srt_mode) == "LISTENER" ? format(
    "srt://%s:%s?streamid=%s",
    aws_cloudformation_stack.mediaconnect_flow.outputs["SourceIngestIp"],
    aws_cloudformation_stack.mediaconnect_flow.outputs["SourceIngestPort"],
    "${local.name_prefix}-stream"
  ) : null
}

output "srt_ingest_instructions" {
  description = "Guidance for connecting your source based on SRT mode."
  value = upper(var.srt_mode) == "LISTENER" ? "Use srt_ingest_url in OBS (Custom -> SRT)." : format(
    "SRT mode is CALLER. Configure your upstream listener to accept a caller from MediaConnect using %s:%s and streamid %s.",
    coalesce(var.srt_caller_source_listener_address, "<set srt_caller_source_listener_address>"),
    tostring(coalesce(var.srt_caller_source_listener_port, 0)),
    "${local.name_prefix}-stream"
  )
}

output "cloudfront_domain_name" {
  description = "CloudFront domain name for playback."
  value       = aws_cloudfront_distribution.hls.domain_name
}

output "cloudfront_playback_url" {
  description = "CloudFront URL to the HLS master manifest."
  value       = "https://${aws_cloudfront_distribution.hls.domain_name}/index.m3u8"
}
