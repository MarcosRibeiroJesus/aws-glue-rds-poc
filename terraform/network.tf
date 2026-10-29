# ------------------------------------------------------------------------------
# Networking: Minimal Private VPC + Free S3 Gateway Endpoint ($0.00 cost)
# No NAT Gateway ($32/mo saved) and No Public IPv4 ($0.005/hr saved)
# ------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# RDS requires a DB subnet group with at least 2 Availability Zones
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-b"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# 100% FREE Gateway VPC Endpoint for S3 so Glue can read scripts & write Parquet without a NAT Gateway
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.project_name}-s3-gateway-endpoint"
  }
}

# Security Group shared by RDS and AWS Glue Connection
# AWS Glue strictly requires a self-referencing inbound rule for all TCP ports
resource "aws_security_group" "glue_rds_sg" {
  name        = "${var.project_name}-glue-rds-sg"
  description = "Security group for GlueVPC connection and private RDS PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Self-referencing rule required by AWS Glue VPC connection and RDS port 5432"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound traffic (to VPC CIDR and S3 Gateway prefix list)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-glue-rds-sg"
  }
}
