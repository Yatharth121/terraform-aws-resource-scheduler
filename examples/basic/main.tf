provider "aws" {
  region = "ca-central-1"
}

# Stops tagged dev resources at 7pm and starts them at 8am on weekdays, Toronto time.
module "scheduler" {
  source = "../.."

  name               = "dev-office-hours"
  schedule_tag_key   = "Schedule"
  schedule_tag_value = "office-hours"
  start_schedule     = "cron(0 8 ? * MON-FRI *)"
  stop_schedule      = "cron(0 19 ? * MON-FRI *)"
  timezone           = "America/Toronto"

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# A resource opts in with one tag.
resource "aws_instance" "example" {
  # checkov:skip=CKV2_AWS_41: demo instance needs no AWS API access, so no instance profile
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  ebs_optimized = true
  monitoring    = true

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name     = "scheduler-demo"
    Schedule = "office-hours"
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

output "function_name" {
  value = module.scheduler.lambda_function_name
}
