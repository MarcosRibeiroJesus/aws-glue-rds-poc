# ------------------------------------------------------------------------------
# Cheapest RDS Setup: Single-AZ PostgreSQL db.t4g.micro (~$0.016/hr or Free Tier)
# Private subnet only (avoids $0.005/hr Public IPv4 charge)
# ------------------------------------------------------------------------------

resource "random_password" "db_password" {
  length           = 16
  special          = false # Avoid URL/JDBC escaping issues
}

locals {
  effective_db_password = var.db_password != "" ? var.db_password : random_password.db_password.result
}

resource "aws_db_subnet_group" "rds" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier             = "${var.project_name}-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = var.db_name
  username               = var.db_username
  password               = local.effective_db_password
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.glue_rds_sg.id]
  availability_zone      = aws_subnet.private_a.availability_zone

  # Cost-saving settings for PoC
  multi_az                = false
  publicly_accessible     = false
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Name = "${var.project_name}-postgres"
  }
}
