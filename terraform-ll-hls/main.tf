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

data "aws_caller_identity" "current" {}

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
    # 100ms is too aggressive for internet RTT in many cases and can cause unrecovered packets.
    MinLatency = 2000
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

  # MediaPackage v2 endpoint URL shape:
  # https://<domain>/<base-path>/index.m3u8
  media_package_url_no_scheme = trimprefix(
    trimprefix(aws_cloudformation_stack.mediapackage_v2.outputs["HlsManifestUrl"], "https://"),
    "http://"
  )
  media_package_path_parts    = split("/", local.media_package_url_no_scheme)
  media_package_origin_domain = local.media_package_path_parts[0]
  media_package_origin_path   = "/${join("/", slice(local.media_package_path_parts, 1, length(local.media_package_path_parts) - 1))}"

  channel_policy_json = jsonencode({
    Version = "2012-10-17"
    Id      = "AllowMediaLiveChannelToIngestToEmpChannel"
    Statement = [{
      Sid       = "AllowMediaLiveRoleToAccessEmpChannel"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.medialive.arn }
      Action    = "mediapackagev2:PutObject"
      Resource  = "arn:aws:mediapackagev2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:channelGroup/${local.name_prefix}-cg/channel/${local.name_prefix}-ch"
    }]
  })

  origin_endpoint_policy_json = jsonencode({
    Version = "2012-10-17"
    Id      = "AnonymousAccessPolicy"
    Statement = [{
      Sid       = "AllowAnonymousAccess"
      Effect    = "Allow"
      Principal = "*"
      Action    = "mediapackagev2:GetObject"
      Resource  = "arn:aws:mediapackagev2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:channelGroup/${local.name_prefix}-cg/channel/${local.name_prefix}-ch/originEndpoint/${local.name_prefix}-ep"
    }]
  })
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
        Sid    = "MediaPackageV2ReadWrite"
        Effect = "Allow"
        Action = [
          "mediapackagev2:GetObject",
          "mediapackagev2:PutObject",
          "mediapackagev2:DescribeChannel",
          "mediapackagev2:DescribeOriginEndpoint",
          "mediapackagev2:GetChannelPolicy",
          "mediapackagev2:GetOriginEndpointPolicy",
          "mediapackagev2:ListChannels",
          "mediapackagev2:ListOriginEndpoints"
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
# Packaging: MediaPackage v2 (HLS + LL-HLS)
#################

resource "aws_cloudformation_stack" "mediapackage_v2" {
  name = "${local.name_prefix}-mpv2"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "MediaPackage v2 resources for HLS and LL-HLS."
    Resources = {
      ChannelGroup = {
        Type = "AWS::MediaPackageV2::ChannelGroup"
        Properties = {
          ChannelGroupName = "${local.name_prefix}-cg"
          Description      = "Channel group for LL-HLS pipeline."
        }
      }
      Channel = {
        Type = "AWS::MediaPackageV2::Channel"
        DependsOn = [
          "ChannelGroup"
        ]
        Properties = {
          ChannelGroupName = "${local.name_prefix}-cg"
          ChannelName      = "${local.name_prefix}-ch"
          InputType        = "CMAF"
        }
      }

      OriginEndpoint = {
        Type = "AWS::MediaPackageV2::OriginEndpoint"
        DependsOn = [
          "ChannelGroup",
          "Channel"
        ]
        Properties = {
          ChannelGroupName  = "${local.name_prefix}-cg"
          ChannelName       = "${local.name_prefix}-ch"
          OriginEndpointName = "${local.name_prefix}-ep"
          ContainerType     = "CMAF"
          Segment = {
            SegmentDurationSeconds = var.hls_segment_duration_seconds
          }
          HlsManifests = [
            {
              ManifestName                   = "index"
              ManifestWindowSeconds          = var.hls_playlist_window_seconds
              ProgramDateTimeIntervalSeconds = 1
            }
          ]
          LowLatencyHlsManifests = [
            {
              ManifestName                   = "indexll"
              ManifestWindowSeconds          = var.hls_playlist_window_seconds
              ProgramDateTimeIntervalSeconds = 1
            }
          ]
        }
      }

    }
    Outputs = {
      HlsManifestUrl = {
        Value = {
          "Fn::Select" = [0, { "Fn::GetAtt" = ["OriginEndpoint", "HlsManifestUrls"] }]
        }
      }
      LlHlsManifestUrl = {
        Value = {
          "Fn::Select" = [0, { "Fn::GetAtt" = ["OriginEndpoint", "LowLatencyHlsManifestUrls"] }]
        }
      }
      IngestUrl = {
        Value = {
          "Fn::Select" = [0, { "Fn::GetAtt" = ["Channel", "IngestEndpointUrls"] }]
        }
      }
      ChannelGroupName = {
        Value = "${local.name_prefix}-cg"
      }
      ChannelName = {
        Value = "${local.name_prefix}-ch"
      }
    }
  })

  tags = var.default_tags
}

#################
# MediaPackage v2 resource policies (applied via AWS CLI to bypass CloudFormation Json-type serialisation issues)
#################

resource "terraform_data" "channel_policy" {
  depends_on = [aws_cloudformation_stack.mediapackage_v2]
  triggers_replace = [local.channel_policy_json]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "[IO.File]::WriteAllText('${abspath(path.module)}/.tmp-ch-policy.json', '${replace(local.channel_policy_json, "'", "''")}'); aws mediapackagev2 put-channel-policy --channel-group-name '${local.name_prefix}-cg' --channel-name '${local.name_prefix}-ch' --region '${var.aws_region}' --policy 'file://${abspath(path.module)}/.tmp-ch-policy.json'"
  }
}

resource "terraform_data" "origin_endpoint_policy" {
  depends_on = [aws_cloudformation_stack.mediapackage_v2, terraform_data.channel_policy]
  triggers_replace = [local.origin_endpoint_policy_json]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = "[IO.File]::WriteAllText('${abspath(path.module)}/.tmp-ep-policy.json', '${replace(local.origin_endpoint_policy_json, "'", "''")}'); aws mediapackagev2 put-origin-endpoint-policy --channel-group-name '${local.name_prefix}-cg' --channel-name '${local.name_prefix}-ch' --origin-endpoint-name '${local.name_prefix}-ep' --region '${var.aws_region}' --policy 'file://${abspath(path.module)}/.tmp-ep-policy.json'"
  }
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

resource "aws_cloudformation_stack" "medialive_channel" {
  name = "${local.name_prefix}-ml-channel"

  depends_on = [
    aws_cloudformation_stack.mediapackage_v2,
    aws_medialive_input.from_mediaconnect,
    aws_cloudformation_stack.mediaconnect_flow
  ]

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "MediaLive channel configured for MediaPackage v2 (LL-HLS capable)."
    Resources = {
      MediaLiveChannel = {
        Type = "AWS::MediaLive::Channel"
        Properties = {
          Name         = "${local.name_prefix}-channel"
          RoleArn      = aws_iam_role.medialive.arn
          ChannelClass = upper(var.medialive_channel_class)

          InputSpecification = {
            Codec           = "AVC"
            MaximumBitrate  = "MAX_20_MBPS"
            Resolution      = "HD"
          }

          Destinations = [
            {
              Id = "cmaf-destination"
              Settings = [
                {
                  Url = aws_cloudformation_stack.mediapackage_v2.outputs["IngestUrl"]
                }
              ]
            }
          ]

          EncoderSettings = {
            TimecodeConfig = { Source = "SYSTEMCLOCK" }
            AudioDescriptions = [
              {
                Name              = "audio_aac"
                AudioSelectorName = "default"
                CodecSettings = {
                  AacSettings = {
                    Bitrate         = 96000
                    CodingMode      = "CODING_MODE_2_0"
                    InputType       = "NORMAL"
                    Profile         = "LC"
                    RateControlMode = "CBR"
                    RawFormat       = "NONE"
                    SampleRate      = 48000
                    Spec            = "MPEG4"
                  }
                }
              }
            ]
            VideoDescriptions = [
              {
                Name   = "video_1080p"
                Width  = 1920
                Height = 1080
                CodecSettings = {
                  H264Settings = {
                    AdaptiveQuantization   = "HIGH"
                    Bitrate                = 5000000
                    FramerateControl       = "SPECIFIED"
                    FramerateNumerator     = var.medialive_output_framerate_numerator
                    FramerateDenominator   = var.medialive_output_framerate_denominator
                    GopBReference          = "ENABLED"
                    GopSize                = 2.0
                    GopSizeUnits           = "SECONDS"
                    Level                  = "H264_LEVEL_AUTO"
                    LookAheadRateControl   = "HIGH"
                    ParControl             = "SPECIFIED"
                    ParNumerator           = 1
                    ParDenominator         = 1
                    Profile                = "HIGH"
                    RateControlMode        = "CBR"
                    SceneChangeDetect      = "ENABLED"
                  }
                }
              }
            ]
            OutputGroups = [
              {
                Name = "cmaf-ingest-group"
                OutputGroupSettings = {
                  CmafIngestGroupSettings = {
                    Destination = {
                      DestinationRefId = "cmaf-destination"
                    }
                    NielsenId3Behavior = "NO_PASSTHROUGH"
                    SegmentLength      = var.hls_segment_duration_seconds
                    SegmentLengthUnits = "SECONDS"
                  }
                }
                Outputs = [
                  {
                    OutputName           = "output_1080p_video"
                    VideoDescriptionName = "video_1080p"
                    OutputSettings = {
                      CmafIngestOutputSettings = {
                        NameModifier = "_video"
                      }
                    }
                  },
                  {
                    OutputName            = "output_aac_audio"
                    AudioDescriptionNames = ["audio_aac"]
                    OutputSettings = {
                      CmafIngestOutputSettings = {
                        NameModifier = "_audio"
                      }
                    }
                  }
                ]
              }
            ]
          }

          InputAttachments = [
            {
              InputId             = aws_medialive_input.from_mediaconnect.id
              InputAttachmentName = "${local.name_prefix}-input-attachment"
            }
          ]
        }
      }
    }
  })

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
  depends_on = [
    aws_cloudformation_stack.mediapackage_v2
  ]

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
