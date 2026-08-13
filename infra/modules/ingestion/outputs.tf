output "secret_arns" {
  value = {
    blizzard   = aws_secretsmanager_secret.blizzard.arn
    aligulac   = aws_secretsmanager_secret.aligulac.arn
    databricks = aws_secretsmanager_secret.databricks.arn
  }
}
