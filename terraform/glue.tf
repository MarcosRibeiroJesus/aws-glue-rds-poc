# ------------------------------------------------------------------------------
# S3 Bucket, Glue Data Catalog, Glue Job (Python Shell 0.0625 DPU),
# Glue Workflow + EventBridge Auto-Trigger on Deployment ($0.00 idle cost)
# ------------------------------------------------------------------------------

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "data_lake" {
  bucket        = "${var.project_name}-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-data-lake"
  }
}

# Enable EventBridge notifications on the S3 bucket ($0.00 cost)
# When Terraform uploads/updates the Glue script in S3, S3 emits `Object Created` to EventBridge
resource "aws_s3_bucket_notification" "bucket_eventbridge" {
  bucket      = aws_s3_bucket.data_lake.id
  eventbridge = true
}

# ------------------------------------------------------------------------------
# Glue Data Catalog Database & Parquet Table ($0.00 cost - free under 1M objects)
# ------------------------------------------------------------------------------

resource "aws_glue_catalog_database" "poc_db" {
  name        = "${replace(var.project_name, "-", "_")}_catalog_db"
  description = "Glue Data Catalog database for RDS to S3 Parquet PoC"
}

resource "aws_glue_catalog_table" "orders_parquet" {
  name          = "orders_parquet"
  database_name = aws_glue_catalog_database.poc_db.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    "parquet.compression" = "SNAPPY"
    "classification"      = "parquet"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake.bucket}/data/orders/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "order_id"
      type = "int"
    }
    columns {
      name = "customer_name"
      type = "string"
    }
    columns {
      name = "category"
      type = "string"
    }
    columns {
      name = "amount"
      type = "double"
    }
    columns {
      name = "order_status"
      type = "string"
    }
    columns {
      name = "amount_with_tax"
      type = "double"
    }
    columns {
      name = "created_at"
      type = "string"
    }
    columns {
      name = "ingested_at_utc"
      type = "string"
    }
  }
}

# ------------------------------------------------------------------------------
# IAM Role for AWS Glue Job
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job_role" {
  name               = "${var.project_name}-glue-job-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${var.project_name}-s3-access"
  role = aws_iam_role.glue_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Glue Network Connection (Places Glue Python Shell job inside the RDS Private Subnet)
# ------------------------------------------------------------------------------

resource "aws_glue_connection" "rds_vpc_conn" {
  name            = "${var.project_name}-rds-vpc-conn"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = aws_subnet.private_a.availability_zone
    subnet_id              = aws_subnet.private_a.id
    security_group_id_list = [aws_security_group.glue_rds_sg.id]
  }
}

# ------------------------------------------------------------------------------
# Glue Job (Python Shell - 0.0625 DPU = ~$0.00046 per 1-minute run)
# ------------------------------------------------------------------------------

locals {
  glue_script_s3_key = "scripts/glue_rds_to_parquet.py"
}

resource "aws_glue_job" "rds_to_parquet" {
  name         = "${var.project_name}-rds-to-parquet"
  role_arn     = aws_iam_role.glue_job_role.arn
  max_capacity = 0.0625 # 1/16 DPU (cheapest possible Glue tier)
  timeout      = 10
  connections  = [aws_glue_connection.rds_vpc_conn.name]

  command {
    name            = "pythonshell"
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/${local.glue_script_s3_key}"
    python_version  = "3.9"
  }

  default_arguments = {
    "--library-set"                      = "analytics" # Includes pandas, pyarrow, pg8000, awswrangler pre-installed
    "--enable-continuous-cloudwatch-log" = "true"
    "--DB_HOST"                          = aws_db_instance.postgres.address
    "--DB_PORT"                          = tostring(aws_db_instance.postgres.port)
    "--DB_NAME"                          = aws_db_instance.postgres.db_name
    "--DB_USER"                          = aws_db_instance.postgres.username
    "--DB_PASS"                          = local.effective_db_password
    "--S3_OUTPUT_PATH"                   = "s3://${aws_s3_bucket.data_lake.bucket}/data/orders/orders.parquet"
  }

  depends_on = [
    aws_vpc_endpoint.s3,
    aws_db_instance.postgres
  ]
}

# ------------------------------------------------------------------------------
# Glue Workflow + EVENT Trigger + EventBridge Rule
# Automatically starts the Glue Workflow whenever the Glue script is deployed!
# ------------------------------------------------------------------------------

resource "aws_glue_workflow" "etl_workflow" {
  name        = "${var.project_name}-workflow"
  description = "Workflow automatically triggered via EventBridge when Glue script is deployed"
}

resource "aws_glue_trigger" "workflow_event_start" {
  name          = "${var.project_name}-event-trigger"
  workflow_name = aws_glue_workflow.etl_workflow.name
  type          = "EVENT"

  actions {
    job_name = aws_glue_job.rds_to_parquet.name
  }
}

# EventBridge Rule matching S3 `Object Created` for the Glue Python script
resource "aws_cloudwatch_event_rule" "glue_script_deployed" {
  name        = "${var.project_name}-script-deployed-rule"
  description = "Fires Glue Workflow EVENT trigger when the Glue Python script is created/updated in S3"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.data_lake.bucket]
      }
      object = {
        key = [local.glue_script_s3_key]
      }
    }
  })
}

# IAM Role allowing EventBridge to send NotifyEvent to the Glue Workflow
data "aws_iam_policy_document" "eventbridge_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_glue_role" {
  name               = "${var.project_name}-eb-glue-workflow-role"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role.json
}

resource "aws_iam_role_policy" "eventbridge_notify_glue" {
  name = "${var.project_name}-eb-notify-glue"
  role = aws_iam_role.eventbridge_glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["glue:NotifyEvent"]
        Resource = [aws_glue_workflow.etl_workflow.arn]
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "trigger_glue_workflow" {
  rule      = aws_cloudwatch_event_rule.glue_script_deployed.name
  target_id = "TriggerGlueWorkflowOnDeploy"
  arn       = aws_glue_workflow.etl_workflow.arn
  role_arn  = aws_iam_role.eventbridge_glue_role.arn
}

# Upload the Glue script AFTER the Glue Job, Workflow, Trigger, and EventBridge rule exist!
# That way, even on the very first `terraform apply`, the S3 upload event immediately triggers the Glue Workflow!
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.data_lake.id
  key    = local.glue_script_s3_key
  source = "${path.module}/../scripts/glue_rds_to_parquet.py"
  etag   = filemd5("${path.module}/../scripts/glue_rds_to_parquet.py")

  # Updating either the script content OR the deployment token re-uploads the object and triggers the workflow
  metadata = {
    script_md5    = filemd5("${path.module}/../scripts/glue_rds_to_parquet.py")
    deploy_token  = var.force_workflow_trigger_token
    glue_job_name = aws_glue_job.rds_to_parquet.name
  }

  depends_on = [
    aws_s3_bucket_notification.bucket_eventbridge,
    aws_glue_job.rds_to_parquet,
    aws_glue_trigger.workflow_event_start,
    aws_cloudwatch_event_target.trigger_glue_workflow
  ]
}
