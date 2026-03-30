########################
# Phase 1 variables & placeholders #
########################

variable "aws_region" {
  description = "AWS region where streaming resources are provisioned."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile (from ~/.aws/config). Leave null to use the default credential chain (env vars, default profile, SSO cache, etc.)."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Global naming prefix for all resources."
  type        = string
  default     = "streaming-project-flow"
}

variable "default_tags" {
  description = "Tags applied to resources that support tags."
  type        = map(string)
  default = {
    project = "streaming-project-flow"
  }
}

variable "mediaconnect_availability_zone" {
  description = "Availability Zone for MediaConnect flow (e.g. us-east-1a)."
  type        = string
  default     = "us-east-1a"
}

variable "mediaconnect_ingest_port" {
  description = "SRT ingest port for MediaConnect in LISTENER mode."
  type        = number
  default     = 5000

  validation {
    condition     = var.mediaconnect_ingest_port >= 1 && var.mediaconnect_ingest_port <= 65535
    error_message = "mediaconnect_ingest_port must be between 1 and 65535."
  }
}

variable "mediaconnect_whitelist_cidr" {
  description = "CIDR allowed to send SRT ingest in LISTENER mode."
  type        = string
  default     = "0.0.0.0/0"
}

variable "srt_mode" {
  description = "SRT mode: LISTENER or CALLER."
  type        = string
  default     = "LISTENER"

  validation {
    condition     = contains(["LISTENER", "CALLER"], upper(var.srt_mode))
    error_message = "srt_mode must be LISTENER or CALLER."
  }
}

variable "srt_caller_source_listener_address" {
  description = "Required when srt_mode is CALLER."
  type        = string
  default     = null

  validation {
    condition = upper(var.srt_mode) != "CALLER" || (
      var.srt_caller_source_listener_address != null &&
      trimspace(var.srt_caller_source_listener_address) != ""
    )
    error_message = "When srt_mode is CALLER, srt_caller_source_listener_address must be set."
  }
}

variable "srt_caller_source_listener_port" {
  description = "Required when srt_mode is CALLER."
  type        = number
  default     = null

  validation {
    condition = upper(var.srt_mode) != "CALLER" || (
      var.srt_caller_source_listener_port != null &&
      var.srt_caller_source_listener_port >= 1 &&
      var.srt_caller_source_listener_port <= 65535
    )
    error_message = "When srt_mode is CALLER, srt_caller_source_listener_port must be between 1 and 65535."
  }
}

variable "medialive_channel_class" {
  description = "MediaLive channel class."
  type        = string
  default     = "SINGLE_PIPELINE"

  validation {
    condition     = contains(["SINGLE_PIPELINE", "STANDARD"], upper(var.medialive_channel_class))
    error_message = "medialive_channel_class must be SINGLE_PIPELINE or STANDARD."
  }
}

# MediaPackage output groups require explicit frame rate and PAR (not INITIALIZE_FROM_SOURCE).
# Match your OBS/output frame rate (e.g. 30/1 = 30 fps, 30000/1001 ≈ 29.97).
# See: https://docs.aws.amazon.com/medialive/latest/ug/outputs-supported-containers-codecs.html
# and Terraform: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/medialive_channel
variable "medialive_output_framerate_numerator" {
  description = "H.264 frame rate numerator when framerate_control is SPECIFIED (MediaPackage outputs)."
  type        = number
  default     = 30
}

variable "medialive_output_framerate_denominator" {
  description = "H.264 frame rate denominator when framerate_control is SPECIFIED (e.g. 1 for integer fps)."
  type        = number
  default     = 1
}

variable "hls_segment_duration_seconds" {
  description = "MediaPackage HLS segment duration."
  type        = number
  default     = 2

  validation {
    condition     = var.hls_segment_duration_seconds == 2
    error_message = "hls_segment_duration_seconds must be 2 to match the assignment requirements."
  }
}

variable "hls_playlist_window_seconds" {
  description = "MediaPackage HLS playlist window."
  type        = number
  default     = 60
}

variable "hls_playlist_type" {
  description = "MediaPackage HLS playlist type."
  type        = string
  default     = "EVENT"

  validation {
    condition     = contains(["NONE", "EVENT", "VOD"], upper(var.hls_playlist_type))
    error_message = "hls_playlist_type must be NONE, EVENT, or VOD."
  }
}

variable "hls_version" {
  description = "Informational target HLS manifest version (V3 or V4). MediaPackage v1 CloudFormation does not expose an explicit HLS version property."
  type        = string
  default     = "V4"

  validation {
    condition     = contains(["V3", "V4"], upper(var.hls_version))
    error_message = "hls_version must be V3 or V4."
  }
}

variable "cloudfront_price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}
