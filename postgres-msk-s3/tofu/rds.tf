resource "aws_security_group" "rds_sg" {
  name        = "allow_postgresql"
  description = "Allow PostgreSQL inbound traffic and all outbound traffic"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_sg_myip" {
  security_group_id = aws_security_group.rds_sg.id
  cidr_ipv4         = var.my_public_ip
  from_port         = 5432
  ip_protocol       = "tcp"
  to_port           = 5432
}

resource "aws_vpc_security_group_ingress_rule" "rds_sg_vpc" {
  security_group_id = aws_security_group.rds_sg.id
  cidr_ipv4         = aws_vpc.main.cidr_block
  from_port         = 5432
  ip_protocol       = "tcp"
  to_port           = 5432
}

resource "aws_vpc_security_group_egress_rule" "rds_sg" {
  security_group_id = aws_security_group.rds_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_parameter_group" "cdc" {
  name        = "rds-pg"
  description = "RDS PostgreSQL Parameter Group for CDC"
  family      = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "5"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "7"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "wal_sender_timeout"
    value = "60000"
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = [aws_subnet.main.id, aws_subnet.secondary.id, aws_subnet.tritary.id]
}

resource "aws_db_instance" "main" {
  identifier             = "msk-rds"
  db_name                = "msk_db"
  engine                 = "postgres"
  engine_version         = "16.8"
  instance_class         = "db.t3.micro"
  username               = "msk_user"
  password               = "msk_password"
  allocated_storage      = 10
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  parameter_group_name   = aws_db_parameter_group.cdc.name
  apply_immediately      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  skip_final_snapshot    = true
  publicly_accessible    = true
}

output "rds" {
  value = {
    db_name  = aws_db_instance.main.db_name
    endpoint = aws_db_instance.main.endpoint
    port     = aws_db_instance.main.port
  }
}
