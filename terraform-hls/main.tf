terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.38"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  name_prefix = var.name_prefix

  mediaconnect_protocol = upper(var.srt_mode) == "CALLER" ? "srt-caller" : "srt-listener"

  # StreamId must NOT be set on SRT Listener sources (MediaConnect API validation).
  # For SRT Caller, StreamId is included on the source per AWS expectations.
  mediaconnect_source_base = {
    Name        = "${local.name_prefix}-source"
    Protocol    = local.mediaconnect_protocol
    Description = "Primary SRT ingest source."
    MaxBitrate  = 50000000
    # MediaConnect requires MinLatency between 10 and 15000 (milliseconds).
    # 100ms can be too low for internet RTT and may cause unrecovered SRT packets.
    MinLatency = 1200
  }

  mediaconnect_source_listener = merge(local.mediaconnect_source_base, {
    IngestPort    = var.mediaconnect_ingest_port
    WhitelistCidr = var.mediaconnect_whitelist_cidr
  })

  mediaconnect_source_caller = merge(local.mediaconnect_source_base, {
    SourceListenerAddress = var.srt_caller_source_listener_address
    SourceListenerPort    = var.srt_caller_source_listener_port
    StreamId              = "${local.name_prefix}-stream"
  })

  mediaconnect_source = upper(var.srt_mode) == "CALLER" ? local.mediaconnect_source_caller : local.mediaconnect_source_listener

  # MediaPackage endpoint URL shape:
  # https://<domain>/out/v1/<endpoint-id>/index.m3u8
  media_package_url_no_scheme = trimprefix(
    trimprefix(aws_cloudformation_stack.mediapackage_hls_endpoint.outputs["HlsEndpointUrl"], "https://"),
    "http://"
  )
  media_package_path_parts    = split("/", local.media_package_url_no_scheme)
  media_package_origin_domain = local.media_package_path_parts[0]
  media_package_origin_path   = "/${join("/", slice(local.media_package_path_parts, 1, length(local.media_package_path_parts) - 1))}"
}

#################
# IAM for MediaLive
#################

resource "aws_iam_role" "medialive" {
  name = "${local.name_prefix}-medialive-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "medialive.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.default_tags
}

resource "aws_iam_role_policy" "medialive" {
  name = "${local.name_prefix}-medialive-policy"
  role = aws_iam_role.medialive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MediaConnectRead"
        Effect = "Allow"
        Action = [
          "mediaconnect:DescribeFlow",
          "mediaconnect:DescribeFlowSource",
          "mediaconnect:ListFlows",
          "mediaconnect:ListFlowSources"
        ]
        Resource = "*"
      },
      {
        Sid    = "MediaConnectManagedByMediaLive"
        Effect = "Allow"
        Action = [
          "mediaconnect:ManagedDescribeFlow",
          "mediaconnect:ManagedAddOutput",
          "mediaconnect:ManagedRemoveOutput"
        ]
        Resource = "*"
      },
      {
        Sid    = "MediaPackageRead"
        Effect = "Allow"
        Action = [
          "mediapackage:DescribeChannel",
          "mediapackage:DescribeOriginEndpoint",
          "mediapackage:ListChannels",
          "mediapackage:ListOriginEndpoints"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      {
        Sid    = "Ec2ReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:Describe*"
        ]
        Resource = "*"
      }
    ]
  })
}

#################
# Ingest: MediaConnect (SRT)
# (via CloudFormation stack because AWS provider does not expose a native MediaConnect Flow resource)
#################

resource "aws_cloudformation_stack" "mediaconnect_flow" {
  name = "${local.name_prefix}-mediaconnect"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "MediaConnect SRT ingest flow."
    Resources = {
      MediaConnectFlow = {
        Type = "AWS::MediaConnect::Flow"
        Properties = {
          Name             = "${local.name_prefix}-flow"
          AvailabilityZone = var.mediaconnect_availability_zone
          Source           = local.mediaconnect_source
        }
      }
    }
    Outputs = {
      FlowArn = {
        Value = {
          "Fn::GetAtt" = ["MediaConnectFlow", "FlowArn"]
        }
      }
      SourceIngestIp = {
        Value = {
          "Fn::GetAtt" = ["MediaConnectFlow", "Source.IngestIp"]
        }
      }
      SourceIngestPort = {
        Value = {
          "Fn::GetAtt" = ["MediaConnectFlow", "Source.SourceIngestPort"]
        }
      }
    }
  })

  tags = var.default_tags
}

#################
# Packaging: MediaPackage (HLS)
#################

resource "aws_media_package_channel" "main" {
  channel_id  = "${local.name_prefix}-channel"
  description = "MediaPackage channel for ABR HLS."
  tags        = var.default_tags
}

resource "aws_cloudformation_stack" "mediapackage_hls_endpoint" {
  name = "${local.name_prefix}-hls-endpoint"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "MediaPackage HLS origin endpoint."
    Resources = {
      HlsEndpoint = {
        Type = "AWS::MediaPackage::OriginEndpoint"
        Properties = {
          ChannelId    = aws_media_package_channel.main.id
          Id           = "${local.name_prefix}-hls"
          ManifestName = "index"
          HlsPackage = {
            SegmentDurationSeconds         = var.hls_segment_duration_seconds
            PlaylistType                   = upper(var.hls_playlist_type)
            PlaylistWindowSeconds          = var.hls_playlist_window_seconds
            ProgramDateTimeIntervalSeconds = 0
            AdMarkers                      = "NONE"
            IncludeIframeOnlyStream        = false
            UseAudioRenditionGroup         = true
          }
        }
      }
    }
    Outputs = {
      HlsEndpointUrl = {
        Value = {
          "Fn::GetAtt" = ["HlsEndpoint", "Url"]
        }
      }
    }
  })

  tags = var.default_tags
}

#################
# Processing: MediaLive ABR transcode (H.264, GOP 2s)
#################

resource "aws_medialive_input" "from_mediaconnect" {
  name     = "${local.name_prefix}-input"
  role_arn = aws_iam_role.medialive.arn
  type     = "MEDIACONNECT"

  # Ensure IAM inline policy is applied before CreateInput (avoids race / eventual consistency).
  depends_on = [aws_iam_role_policy.medialive]

  media_connect_flows {
    flow_arn = aws_cloudformation_stack.mediaconnect_flow.outputs["FlowArn"]
  }

  tags = var.default_tags
}

resource "aws_medialive_channel" "abr" {
  name          = "${local.name_prefix}-channel"
  role_arn      = aws_iam_role.medialive.arn
  channel_class = upper(var.medialive_channel_class)

  depends_on = [
    aws_cloudformation_stack.mediapackage_hls_endpoint
  ]

  input_specification {
    codec            = "AVC"
    maximum_bitrate  = "MAX_20_MBPS"
    input_resolution = "HD"
  }

  destinations {
    id = "mediapackage-destination"

    media_package_settings {
      channel_id = aws_media_package_channel.main.id
    }
  }

  encoder_settings {
    timecode_config {
      source = "SYSTEMCLOCK"
    }

    audio_descriptions {
      name                = "audio_aac"
      audio_selector_name = "default"

      codec_settings {
        aac_settings {
          bitrate           = 96000
          coding_mode       = "CODING_MODE_2_0"
          input_type        = "NORMAL"
          profile           = "LC"
          rate_control_mode = "CBR"
          raw_format        = "NONE"
          sample_rate       = 48000
          spec              = "MPEG4"
        }
      }
    }

    video_descriptions {
      name   = "video_1080p"
      width  = 1920
      height = 1080

      codec_settings {
        h264_settings {
          adaptive_quantization   = "HIGH"
          bitrate                 = 5000000
          framerate_control       = "SPECIFIED"
          framerate_numerator     = var.medialive_output_framerate_numerator
          framerate_denominator   = var.medialive_output_framerate_denominator
          gop_b_reference         = "ENABLED"
          gop_size                = 2.0
          gop_size_units          = "SECONDS"
          level                   = "H264_LEVEL_AUTO"
          look_ahead_rate_control = "HIGH"
          par_control             = "SPECIFIED"
          par_numerator           = 1
          par_denominator         = 1
          profile                 = "HIGH"
          rate_control_mode       = "CBR"
          scene_change_detect     = "ENABLED"
        }
      }
    }

    video_descriptions {
      name   = "video_720p"
      width  = 1280
      height = 720

      codec_settings {
        h264_settings {
          adaptive_quantization   = "HIGH"
          bitrate                 = 3000000
          framerate_control       = "SPECIFIED"
          framerate_numerator     = var.medialive_output_framerate_numerator
          framerate_denominator   = var.medialive_output_framerate_denominator
          gop_b_reference         = "ENABLED"
          gop_size                = 2.0
          gop_size_units          = "SECONDS"
          level                   = "H264_LEVEL_AUTO"
          look_ahead_rate_control = "HIGH"
          par_control             = "SPECIFIED"
          par_numerator           = 1
          par_denominator         = 1
          profile                 = "HIGH"
          rate_control_mode       = "CBR"
          scene_change_detect     = "ENABLED"
        }
      }
    }

    video_descriptions {
      name   = "video_480p"
      width  = 854
      height = 480

      codec_settings {
        h264_settings {
          adaptive_quantization   = "HIGH"
          bitrate                 = 1000000
          framerate_control       = "SPECIFIED"
          framerate_numerator     = var.medialive_output_framerate_numerator
          framerate_denominator   = var.medialive_output_framerate_denominator
          gop_b_reference         = "ENABLED"
          gop_size                = 2.0
          gop_size_units          = "SECONDS"
          level                   = "H264_LEVEL_AUTO"
          look_ahead_rate_control = "HIGH"
          par_control             = "SPECIFIED"
          par_numerator           = 1
          par_denominator         = 1
          profile                 = "MAIN"
          rate_control_mode       = "CBR"
          scene_change_detect     = "ENABLED"
        }
      }
    }

    output_groups {
      name = "mediapackage-group"

      output_group_settings {
        media_package_group_settings {
          destination {
            destination_ref_id = "mediapackage-destination"
          }
        }
      }

      outputs {
        output_name             = "output_1080p"
        audio_description_names = ["audio_aac"]
        video_description_name  = "video_1080p"

        output_settings {
          media_package_output_settings {}
        }
      }

      outputs {
        output_name             = "output_720p"
        audio_description_names = ["audio_aac"]
        video_description_name  = "video_720p"

        output_settings {
          media_package_output_settings {}
        }
      }

      outputs {
        output_name             = "output_480p"
        audio_description_names = ["audio_aac"]
        video_description_name  = "video_480p"

        output_settings {
          media_package_output_settings {}
        }
      }
    }
  }

  input_attachments {
    input_id              = aws_medialive_input.from_mediaconnect.id
    input_attachment_name = "${local.name_prefix}-input-attachment"
  }

  tags = var.default_tags
}

#################
# Distribution: CloudFront -> MediaPackage HLS origin
#################

resource "aws_cloudfront_response_headers_policy" "hls_cors" {
  name    = "${local.name_prefix}-hls-cors"
  comment = "CORS headers so browsers can fetch HLS from any page origin (file, localhost, etc.)."

  cors_config {
    access_control_allow_credentials = false
    origin_override                  = true

    access_control_allow_headers {
      items = ["*"]
    }
    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }
    access_control_allow_origins {
      items = ["*"]
    }
    access_control_expose_headers {
      items = ["*"]
    }
    access_control_max_age_sec = 86400
  }
}

resource "aws_cloudfront_distribution" "hls" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name_prefix}-distribution"
  price_class     = var.cloudfront_price_class

  origin {
    domain_name = local.media_package_origin_domain
    origin_id   = "mediapackage-hls-origin"
    origin_path = local.media_package_origin_path

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "mediapackage-hls-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.hls_cors.id

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      headers      = []

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 30
    default_ttl = 120
    max_ttl     = 300
  }

  # Keep playlist caching short for live edge updates.
  ordered_cache_behavior {
    path_pattern           = "*.m3u8"
    target_origin_id       = "mediapackage-hls-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.hls_cors.id

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers = [
        "Origin",
        "Access-Control-Request-Headers",
        "Access-Control-Request-Method"
      ]

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 2
    max_ttl     = 5
  }

  # LL-HLS part/segment requests often include query parameters (e.g. _HLS_part).
  # Cache them with a short TTL and forward the query string so the player can fetch the correct parts.
  ordered_cache_behavior {
    path_pattern           = "*.m4s"
    target_origin_id       = "mediapackage-hls-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.hls_cors.id

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = []

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 2
    max_ttl     = 10
  }

  ordered_cache_behavior {
    path_pattern           = "*.ts"
    target_origin_id       = "mediapackage-hls-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.hls_cors.id

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = []

      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 2
    max_ttl     = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = var.default_tags
}
