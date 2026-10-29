output "s3_bucket_name" {
  description = "S3 Data Lake bucket storing the Glue script and Parquet output"
  value       = aws_s3_bucket.data_lake.bucket
}

output "parquet_s3_uri" {
  description = "S3 URI where the Glue job writes the transformed Parquet file"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/data/orders/"
}

output "glue_workflow_name" {
  description = "Name of the AWS Glue Workflow automatically triggered via EventBridge"
  value       = aws_glue_workflow.etl_workflow.name
}

output "glue_job_name" {
  description = "Name of the AWS Glue Python Shell Job"
  value       = aws_glue_job.rds_to_parquet.name
}

output "glue_catalog_database" {
  description = "Glue Data Catalog Database name"
  value       = aws_glue_catalog_database.poc_db.name
}

output "glue_catalog_table" {
  description = "Glue Data Catalog Parquet Table name"
  value       = aws_glue_catalog_table.orders_parquet.name
}

output "rds_endpoint" {
  description = "Private RDS PostgreSQL endpoint (inside VPC)"
  value       = aws_db_instance.postgres.endpoint
}
