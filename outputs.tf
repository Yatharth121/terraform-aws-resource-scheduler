output "lambda_function_name" {
  description = "Name of the scheduler Lambda function."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "ARN of the scheduler Lambda function."
  value       = aws_lambda_function.this.arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM role the function runs as."
  value       = aws_iam_role.lambda.arn
}

output "schedule_arns" {
  description = "ARNs of the start and stop schedules."
  value       = { for k, s in aws_scheduler_schedule.this : k => s.arn }
}

output "log_group_name" {
  description = "CloudWatch log group for the function."
  value       = aws_cloudwatch_log_group.lambda.name
}
