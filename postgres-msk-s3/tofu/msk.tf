# role
resource "aws_iam_role" "msk_connector" {
  name = "MSKConnectorRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "kafkaconnect.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = "${var.account_id}"
          }
        }
      }
    ]
  })
}

resource "aws_iam_policy" "msk_connector_policy" {
  name        = "MSKConnectorPolicy"
  description = "Policy for MSK Connector Role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "msk_connector_attach" {
  role       = aws_iam_role.msk_connector.name
  policy_arn = aws_iam_policy.msk_connector_policy.arn
}

# sg
resource "aws_security_group" "msk_sg" {
  name   = "allow_msk"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "msk_sg_myip" {
  security_group_id = aws_security_group.msk_sg.id
  cidr_ipv4         = var.my_public_ip
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "msk_vpc" {
  security_group_id = aws_security_group.msk_sg.id
  cidr_ipv4         = aws_vpc.main.cidr_block
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "msk_sg_all" {
  security_group_id = aws_security_group.msk_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# cw
resource "aws_cloudwatch_log_group" "msk" {
  name = "msk_broker_logs"
}

resource "aws_cloudwatch_log_group" "connector" {
  name = "msk_connector_logs"
}

# msk
resource "aws_kms_key" "msk_secret_kms" {
  description             = "KMS key for encrypting MSK secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "scram_secret" {
  name       = "AmazonMSK_scram_auth"
  kms_key_id = aws_kms_key.msk_secret_kms.arn
}

resource "aws_secretsmanager_secret_version" "scram_secret_version" {
  secret_id = aws_secretsmanager_secret.scram_secret.id
  secret_string = jsonencode({
    username = "msk_user"
    password = "VeryStrongPassword123"
  })
}

resource "aws_msk_cluster" "main" {
  cluster_name           = "msk-cluster"
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 3

  client_authentication {
    sasl {
      iam   = true
      scram = true
    }

    unauthenticated = true
  }

  broker_node_group_info {
    instance_type  = "kafka.t3.small" # "kafka.m5.large"
    client_subnets = [aws_subnet.main.id, aws_subnet.secondary.id, aws_subnet.tritary.id]
    storage_info {
      ebs_storage_info {
        volume_size = 1
      }
    }
    security_groups = [aws_security_group.msk_sg.id]
    connectivity_info {
      public_access {
        type = "DISABLED" # use "SERVICE_PROVIDED_EIPS" as separate job to enable existing cluster
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.scram_config.arn
    revision = aws_msk_configuration.scram_config.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }
}

resource "aws_msk_single_scram_secret_association" "scram_secret" {
  cluster_arn = aws_msk_cluster.main.arn
  secret_arn  = aws_secretsmanager_secret.scram_secret.arn
}

output "msk_cluster" {
  value = aws_msk_cluster.main
}

resource "aws_msk_configuration" "scram_config" {
  kafka_versions = ["3.8.x"]
  name           = "main"

  server_properties = <<PROPERTIES
auto.create.topics.enable = true
delete.topic.enable = true
PROPERTIES
}

resource "aws_s3_object" "upload_debezium_postgres_source_connector" {
  bucket = aws_s3_bucket.connectors.id
  key    = "debezium-connector-postgres-2.3.7.Final.zip"
  source = "${path.root}/connectors/debezium-connector-postgres-2.3.7.Final.zip"
}

resource "aws_s3_object" "upload_amazon_s3_sink_connector" {
  bucket = aws_s3_bucket.connectors.id
  key    = "confluentinc-kafka-connect-s3-10.6.7.zip"
  source = "${path.root}/connectors/confluentinc-kafka-connect-s3-10.6.7.zip"
}

resource "aws_mskconnect_custom_plugin" "postgres_source" {
  name         = "debezium-connector-postgresql"
  content_type = "ZIP"
  location {
    s3 {
      bucket_arn = aws_s3_bucket.connectors.arn
      file_key   = aws_s3_object.upload_debezium_postgres_source_connector.key
    }
  }
}

resource "aws_mskconnect_custom_plugin" "s3_sink" {
  name         = "confluentinc-kafka-connect-s3"
  content_type = "ZIP"
  location {
    s3 {
      bucket_arn = aws_s3_bucket.connectors.arn
      file_key   = aws_s3_object.upload_amazon_s3_sink_connector.key
    }
  }
}

# connectors
resource "aws_mskconnect_connector" "postgres_source" {
  name = "debezium-postgres-connector"

  kafkaconnect_version = "2.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    # Required Debezium/Connector Properties
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"       = "1"
    # PostgreSQL Connection Configuration
    "database.hostname" = aws_db_instance.main.address
    "database.port"     = aws_db_instance.main.port
    "database.user"     = aws_db_instance.main.username
    "database.password" = aws_db_instance.main.password
    "database.dbname"   = aws_db_instance.main.db_name
    # Replication Slot & Publication Settings
    "plugin.name"                 = "pgoutput"
    "slot.drop.on.stop"           = "false"
    "publication.autocreate.mode" = "filtered"
    "decimal.handling.mode"       = "string"
    "time.precision.mode"         = "adaptive_time_microseconds"
    # Table Filtering and Scope
    "topic.prefix"                   = "postgres"
    "table.include.list"             = "public.student"
    "database.sslmode"               = "require"
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.main.bootstrap_brokers_sasl_iam

      vpc {
        security_groups = [aws_security_group.msk_sg.id]
        subnets         = [aws_subnet.main.id, aws_subnet.secondary.id, aws_subnet.tritary.id]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.postgres_source.arn
      revision = aws_mskconnect_custom_plugin.postgres_source.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connector.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connector.name
      }
    }
  }
}

resource "aws_mskconnect_connector" "s3_sink" {
  name = "DebeziumS3SinkConnector"

  kafkaconnect_version = "2.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    # Core Configuration
    "connector.class" = "io.confluent.connect.s3.S3SinkConnector"
    "s3.region"       = "us-east-1"
    "s3.bucket.name"  = aws_s3_bucket.main.bucket
    "tasks.max"       = "1"
    # Data Format and Conversion
    "format.class"                   = "io.confluent.connect.s3.format.json.JsonFormat"
    "key.converter"                  = "org.apache.kafka.connect.storage.StringConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"
    "schema.compatibility"           = "NONE"
    "behavior.on.null.values"        = "ignore"
    # Topic and Flush Settings
    "flush.size" = "1"
    "topics"     = "postgres.public.student"
    # Partitioning and Storage
    "partitioner.class" = "io.confluent.connect.storage.partitioner.DefaultPartitioner"
    "storage.class"     = "io.confluent.connect.s3.storage.S3Storage"
    # Error Handling (Best Practice)
    "errors.log.include.messages" = "true"
    "errors.log.enable"           = "true"
    "errors.tolerance"            = "all"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.main.bootstrap_brokers_sasl_iam

      vpc {
        security_groups = [aws_security_group.msk_sg.id]
        subnets         = [aws_subnet.main.id, aws_subnet.secondary.id, aws_subnet.tritary.id]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.s3_sink.arn
      revision = aws_mskconnect_custom_plugin.s3_sink.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connector.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connector.name
      }
    }
  }
}
