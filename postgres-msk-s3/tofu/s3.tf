resource "aws_s3_bucket" "main" {
  bucket = "msk-bucket-d7848a5b-3c58-4379-b05f-5ec77b404b0c"
}

resource "aws_s3_bucket" "connectors" {
  bucket = "kafka-connectors-d7848a5b-3c58-4379-b05f-5ec77b404b0c"
}

resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.main.id]
}
