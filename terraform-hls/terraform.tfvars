aws_region                     = "eu-west-2"
mediaconnect_availability_zone = "eu-west-2a"
mediaconnect_whitelist_cidr    = "0.0.0.0/0"
srt_mode                       = "LISTENER"

default_tags = {
  project     = "streaming-project-flow"
  environment = "dev"
}
