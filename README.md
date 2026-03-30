# AWS Live Streaming Pipeline

This project provisions and demonstrates two end-to-end AWS live streaming workflows:

- Ingest with AWS MediaConnect over SRT
- Transcode with AWS MediaLive into ABR H.264 (1080p/720p/480p)
- Package with AWS MediaPackage:
  - Standard HLS (`terraform-hls`)
  - LL-HLS (`terraform-ll-hls`)
- Distribute with Amazon CloudFront
- Play with a standalone Hls.js web player

## Architecture

High-Level View Architecture Diagram

## Project Structure

- `terraform-hls/main.tf` - core HLS pipeline (MediaPackage v1)
- `terraform-hls/variables.tf` - HLS input variables and validation rules
- `terraform-hls/outputs.tf` - HLS ingest/playback outputs
- `terraform-hls/terraform.tfvars` - HLS environment values
- `terraform-ll-hls/main.tf` - LL-HLS pipeline (MediaPackage v2 + MediaLive via CloudFormation)
- `terraform-ll-hls/variables.tf` - LL-HLS input variables and validation rules
- `terraform-ll-hls/outputs.tf` - LL-HLS + HLS playback outputs
- `terraform-ll-hls/terraform.tfvars` - LL-HLS environment values
- `web-player/index.html` - standalone Hls.js player with HLS/LL-HLS toggle and live analytics panel
- `STUDY_GUIDE.md` - concise interview preparation notes

## Region choice for this project

For fair protocol comparison, both stacks are pinned to:

- `aws_region = eu-west-2`
- `mediaconnect_availability_zone = eu-west-2a`

However, it would be a better option to use UAE region for running terraform-ll-hls project because it supports both LL-HLS and HLS and all of that is covered within me-central-1 (UAE) which is close to Saudi Arabia. Unfortunately, this option is not available at the moment, it will be once the terraform-ll-hls development and testing is done.

Why:

- You need HLS and LL-HLS in the same region to compare latency fairly.
- `me-central-1` (UAE) supports MediaPackage v2 live workflows, but the original HLS stack is MediaPackage v1-based (terraform-hls).
- Running one protocol in UAE and the other in London introduces region/network bias.

## Prerequisites

- Windows 11 / macOS / Linux (any OS that can run Terraform CLI)
- Terraform 1.5+
- AWS account with permissions for MediaConnect, MediaLive, MediaPackage, IAM, CloudFront, and CloudFormation
- AWS credentials configured (for example via `aws configure`)
- OBS Studio (recommended) for ingest testing on your OS (Windows steps are detailed below; macOS/Linux typically use the same “Custom -> SRT” concept, or you can push SRT with `ffmpeg`)

Compatibility note: the AWS/Terraform parts and the `web-player` are OS-agnostic (Windows/macOS/Linux). The only OS-specific piece is how you configure/push SRT from your encoder (OBS/ffmpeg).

### AWS credentials for Terraform

Terraform uses the same credential rules as the AWS SDK. If `terraform plan` fails with **No valid credential sources found**:

1. In the **same** terminal, run `aws sts get-caller-identity`. If that fails, fix credentials first (`aws configure`, or `aws sso login` if you use SSO). Personally, I used `aws configure` to set the access key and secret key with proper permissions and it is working.
2. If you use a **named profile**, set it for the session before Terraform:
  ```powershell
   $env:AWS_PROFILE = "your-profile-name"
   terraform plan
  ```
   Or set `aws_profile = "your-profile-name"` in `terraform.tfvars` (see `variables.tf`).
3. The message about **EC2 IMDS** is normal on a laptop: Terraform tries instance metadata last and times out. It does not mean you must use EC2.

## Deploy

This project pins the **HashiCorp AWS provider** to **6.38.x** (`~> 6.38` in each stack). Apply stacks separately:

```powershell
cd terraform-hls
terraform init -upgrade
terraform plan
terraform apply
```

Upgrading from provider 5.x to 6.x does not change the resources used here in a breaking way for this stack, but `init -upgrade` refreshes `.terraform.lock.hcl` and downloads the matching provider binary.

The MediaLive IAM role includes **MediaConnect managed** actions (`mediaconnect:ManagedDescribeFlow`, `ManagedAddOutput`, `ManagedRemoveOutput`) required when MediaLive attaches to a MediaConnect flow as an input ([MediaLive trusted entity requirements](https://docs.aws.amazon.com/medialive/latest/ug/trusted-entity-requirements.html)).

Capture the generated outputs:

```powershell
terraform output srt_ingest_url
terraform output cloudfront_playback_url
```

Deploy the LL-HLS stack separately (Not Ready Yet, Ignore it):

```powershell
cd ../terraform-ll-hls
terraform init -upgrade
terraform plan
terraform apply
```

Recommended comparison workflow:

1. Apply `terraform-hls` and capture `cloudfront_playback_url`.
2. Apply `terraform-ll-hls` and capture `cloudfront_playback_url_ll_hls`.
3. Open the web player with both URLs:

```text
web-player/index.html?hls=<HLS_URL>&ll=<LL_HLS_URL>
```

## Start Flow + Channel (after `terraform apply`)

`terraform apply` provisions the MediaConnect flow and the MediaLive channel configuration, but **both are left in a stopped state** in this stack.

You should:

1. Start the **MediaConnect flow** first (so it begins accepting SRT on the ingest IP/port).
2. Start the **MediaLive channel** second (so it begins pulling from the started flow).

Billing warning: **MediaLive charges while the channel is running**, and MediaConnect flow resources also incur costs. CloudFront will also generate charges for data transfer and requests. When testing is done, stop the channel/flow (for example with `aws medialive stop-channel` and `aws mediaconnect stop-flow`) to avoid unnecessary billing.

Note: you can start MediaConnect flow and MediaLive channel using AWS console (if you have proper access), and the following commands for running the flow and the channel will not be necessary.


### Windows 11 (PowerShell)

1. Start MediaConnect flow

```powershell
$region = "YOUR_REGION" # recommended here: eu-west-2
$flowArn = terraform output -raw mediaconnect_flow_arn
aws mediaconnect start-flow --region $region --flow-arn $flowArn
```

1. Start MediaLive channel (look up the channel id by name)

```powershell
$region = "YOUR_REGION"
$channelName = "YOUR_CHANNEL_NAME" # ex: streaming-project-flow-channel (HLS) or streaming-project-flow-llhls-channel (LL-HLS)
$query = "Channels[?Name=='$channelName'].Id | [0]"
$channelId = aws medialive list-channels --region $region --max-results 100 --query $query --output text
aws medialive start-channel --region $region --channel-id $channelId
```

### macOS / Linux (bash/zsh)

1. Start MediaConnect flow

```bash
region="YOUR_REGION" # recommended here: eu-west-2
flowArn="$(terraform output -raw mediaconnect_flow_arn)"
aws mediaconnect start-flow --region "$region" --flow-arn "$flowArn"
```

1. Start MediaLive channel (look up channel id by name)

```bash
region="YOUR_REGION"
channelName="YOUR_CHANNEL_NAME" # ex: streaming-project-flow-channel (HLS) or streaming-project-flow-llhls-channel (LL-HLS)
channelId="$(aws medialive list-channels --region "$region" --max-results 100 --query "Channels[?Name=='$channelName'].Id | [0]" --output text)"
aws medialive start-channel --region "$region" --channel-id "$channelId"
```

### Check status (optional - macOS/Linux example)

```bash
aws mediaconnect describe-flow --region "$region" --flow-arn "$flowArn"
aws medialive describe-channel --region "$region" --channel-id "$channelId"
```

## Region AZ selection (MediaConnect)

MediaConnect needs an **Availability Zone**. In this repo it is controlled by `mediaconnect_availability_zone` in each stack's `terraform.tfvars`.

Current values used for both stacks:

- `eu-west-2` + `eu-west-2a`

To list AZs for your region:

```bash
aws ec2 describe-availability-zones --region eu-west-2 --query "AvailabilityZones[].ZoneName" --output text
```

## How to Run (OBS + SRT)

### 1) Verify SRT mode

The default in `terraform.tfvars` is `srt_mode = "LISTENER"` (recommended for OBS pushing to AWS).

### 2) Use the SRT ingest URL output

For LISTENER mode, output format is:

```text
srt://<ingest-ip>:<port>?streamid=<streamid>
```

This is exported directly as `srt_ingest_url`.

### 3) Configure OBS Studio

1. Open **Settings -> Stream**
2. Set **Service** to **Custom**
3. Set protocol to **SRT** (or paste full SRT URL if your OBS version supports URL-style input)
4. Paste the Terraform output value from `srt_ingest_url`
5. Start streaming

If video does not arrive, check:

- `mediaconnect_whitelist_cidr` allows your source IP
- local/network firewall allows outbound SRT/UDP to the ingest port
- MediaLive channel is started in AWS (if not automatically started)

### 4) Play from CloudFront

Use:

- `cloudfront_playback_url` from `terraform-hls` for standard HLS.
- `cloudfront_playback_url_ll_hls` from `terraform-ll-hls` for LL-HLS.

`web-player/index.html` runs on any static web server (for example VS Code’s **“Live Server”** extension). This is usually smoother than opening `file://...` URLs directly in the browser.

The web player supports side-by-side toggle:

```text
web-player/index.html?hls=<cloudfront_playback_url from terraform-hls>&ll=<cloudfront_playback_url_ll_hls from terraform-ll-hls>
```

Use `mediapackage_hls_origin_url` / `mediapackage_ll_hls_origin_url` only for debugging (direct origin behavior/caching may differ from CloudFront).

## Outputs Reference


| Output                        | Purpose                                                  |
| ----------------------------- | -------------------------------------------------------- |
| `srt_ingest_url`              | OBS ingest URL for LISTENER mode                         |
| `srt_ingest_instructions`     | Guidance when using CALLER mode                          |
| `cloudfront_playback_url`     | Public playback URL via CDN (standard HLS manifest)      |
| `cloudfront_domain_name`      | CloudFront distribution domain                           |
| `mediapackage_hls_origin_url` | Direct MediaPackage endpoint URL (standard HLS manifest) |
| `mediaconnect_flow_arn`       | MediaConnect flow ARN                                    |


Additional outputs in `terraform-ll-hls`:


| Output                           | Purpose                                     |
| -------------------------------- | ------------------------------------------- |
| `cloudfront_playback_url_hls`    | Standard HLS playback URL from LL-HLS stack |
| `cloudfront_playback_url_ll_hls` | LL-HLS playback URL from LL-HLS stack       |
| `mediapackage_ll_hls_origin_url` | Direct MediaPackage v2 LL-HLS origin URL    |


## MediaLive configuration notes

The two stacks configure MediaLive differently:

1. `**terraform-hls**` uses Terraform resource `**[aws_medialive_channel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/medialive_channel)**` targeting MediaPackage v1.
2. `**terraform-ll-hls**` uses **CloudFormation `AWS::MediaLive::Channel`** because MediaPackage v2 destination settings are needed for CMAF/LL-HLS pathing.
3. **Service rules still apply in both stacks**: for MediaPackage outputs, explicit frame rate (`framerate_control = SPECIFIED`) and pixel aspect ratio (`par_control = SPECIFIED`, 1:1) are required.

Set `medialive_output_framerate_numerator` / `medialive_output_framerate_denominator` in each stack’s `terraform.tfvars` to match OBS output (for example `30` and `1` for 30 fps).

## Notes

- `hls_segment_duration_seconds` is constrained to 2 seconds to match assignment requirements.
- `hls_version` is informational in both stacks.
- In `terraform-hls` (MediaPackage v1), CloudFormation `AWS::MediaPackage::OriginEndpoint` (`HlsPackage`) does not expose a direct HLS v3/v4 selector.
- In `terraform-ll-hls` (MediaPackage v2), manifest behavior is controlled by v2 origin endpoint manifest blocks (`HlsManifests`, `LowLatencyHlsManifests`) rather than a direct v3/v4 switch.

## DASH vs HLS (quick comparison)

- **Manifest format**: DASH uses an `MPD` (XML) manifest; HLS uses `m3u8` playlists (`master.m3u8` + variant playlists).
- **Common container approach**: both are commonly paired with CMAF fragmented MP4 for modern workflows; HLS also historically uses MPEG-2 TS segments.
- **Player/device support**: HLS is very widely supported across iOS/Safari and many broadcast-oriented players; DASH is common in Android/OTT ecosystems.
- **CDN behavior**: both work well with CDNs; HLS has many “classic” caching patterns (manifest frequently updated, segments cached), while DASH often relies on chunk/segment caching plus MPD update strategy.
- **Latency options**: HLS can be extended toward low latency (LL-HLS); DASH can also be chunked for lower latency, but implementation details vary heavily by packager/CDN/player.
- **Operational complexity**: HLS is often simpler to deploy for “web + mobile browser” audiences; DASH can be simpler if you already operate a DASH+CMAF toolchain.