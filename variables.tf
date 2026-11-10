variable "name" {
  description = "Name prefix for the Lambda function, IAM roles and schedules."
  type        = string
  default     = "resource-scheduler"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-_]{1,40}$", var.name))
    error_message = "name must be 1-40 characters: letters, numbers, hyphens or underscores."
  }
}

variable "schedule_tag_key" {
  description = "Tag key that opts a resource into scheduling."
  type        = string
  default     = "Schedule"
}

variable "schedule_tag_value" {
  description = "Tag value that opts a resource into scheduling."
  type        = string
  default     = "office-hours"
}

variable "start_schedule" {
  description = "EventBridge Scheduler expression for starting resources."
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "stop_schedule" {
  description = "EventBridge Scheduler expression for stopping resources."
  type        = string
  default     = "cron(0 19 ? * MON-FRI *)"
}

variable "timezone" {
  description = "IANA time zone the schedules run in. Daylight saving is handled by EventBridge Scheduler."
  type        = string
  default     = "America/Toronto"
}

variable "enable_ec2" {
  description = "Schedule tagged EC2 instances."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Schedule tagged RDS instances and Aurora clusters."
  type        = bool
  default     = true
}

variable "enable_ecs" {
  description = "Schedule tagged ECS services by setting desired count to 0 and restoring it."
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "Log what would change without starting or stopping anything."
  type        = bool
  default     = false
}

variable "schedules_enabled" {
  description = "Set to false to pause both schedules without destroying them."
  type        = bool
  default     = true
}

variable "kms_key_arns" {
  description = "KMS keys used by encrypted EBS volumes on scheduled instances. EC2 can't start those instances unless the function can create grants on these keys."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "How long to keep the function's CloudWatch logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
