provider "aws" {
  region = "us-east-1"
}

# IAM Role for Lambda Execution
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Attach Lambda Basic Execution Policy
resource "aws_iam_policy_attachment" "lambda_logging" {
  name       = "lambda_logging_policy_attachment"
  roles      = [aws_iam_role.lambda_exec.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Attach Lambda VPC Access Policy
resource "aws_iam_policy_attachment" "lambda_vpc_access" {
  name       = "lambda_vpc_access_policy_attachment"
  roles      = [aws_iam_role.lambda_exec.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# IAM Policy to Allow Invoking Fetch Lambda
resource "aws_iam_policy" "invoke_fetch_lambda" {
  name = "InvokeFetchLambda"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "lambda:InvokeFunction",
      Effect = "Allow",
      Resource = "arn:aws:lambda:us-east-1:203918882764:function:cloud-balance-local-fetch"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_invoke_fetch_to_backend" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.invoke_fetch_lambda.arn
}

# Security Group for RDS (initially without inbound rules)
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Allow PostgreSQL access"
  vpc_id      = "vpc-0e64c10620ffbf014"
}

# Security Group for Lambda (initially without egress rules)
resource "aws_security_group" "lambda_sg" {
  name        = "lambda-security-group"
  description = "Allow Lambda to access RDS and VPC endpoints"
  vpc_id      = "vpc-0e64c10620ffbf014"
}

# RDS Inbound Rule to Allow Lambda Security Group
resource "aws_security_group_rule" "rds_inbound" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_sg.id
  source_security_group_id = aws_security_group.lambda_sg.id
}

# Lambda Egress Rule to Allow Access to RDS and Internet (via NAT or endpoints)
resource "aws_security_group_rule" "lambda_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.lambda_sg.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# RDS PostgreSQL Database
resource "aws_db_instance" "cloud_balance_db" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "15.8"
  instance_class       = "db.t3.micro"
  db_name              = var.db_name
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.postgres15"
  skip_final_snapshot  = true
  publicly_accessible  = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

# Lambda Function
resource "aws_lambda_function" "backend_lambda" {
  function_name    = "cloud_balance_backend"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "src/index.handler"
  runtime          = "nodejs18.x"
  filename         = "lambda.zip"
  source_code_hash = filebase64sha256("lambda.zip")
  timeout          = 300

  vpc_config {
    subnet_ids         = ["subnet-0aad0b120e1ecf4e6", "subnet-05f8962b75a12010c"]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      DATABASE_URL                = "postgres://testuser:testpassword@${aws_db_instance.cloud_balance_db.endpoint}/cloud_balance_db"
      BASE_PATH                   = "/dev"
      NODE_ENV                    = "production"
      FETCH_AWS_DATA_LAMBDA_NAME = "cloud-balance-local-fetch"
    }
  }
}

# VPC Endpoint for Lambda API to enable private Lambda invoke
#resource "aws_vpc_endpoint" "lambda_api" {
#  vpc_id            = "vpc-0e64c10620ffbf014"
#  service_name      = "com.amazonaws.us-east-1.lambda"
#  vpc_endpoint_type = "Interface"
#  subnet_ids        = ["subnet-0aad0b120e1ecf4e6", "subnet-05f8962b75a12010c"]
#  security_group_ids = [aws_security_group.lambda_sg.id]
#  private_dns_enabled = true
#}

# API Gateway
resource "aws_apigatewayv2_api" "http_api" {
  name          = "CloudBalanceAPI"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "dev"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.backend_lambda.invoke_arn
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# Create Cognito User Pool
resource "aws_cognito_user_pool" "cloud_balance_user_pool" {
  name = "cloud_balance_user_pool"
}

resource "aws_cognito_user_pool_client" "cloud_balance_client" {
  name         = "cloud_balance_client"
  user_pool_id = aws_cognito_user_pool.cloud_balance_user_pool.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows = ["code"]
  allowed_oauth_scopes = ["email", "openid", "profile"]

  callback_urls = ["http://localhost:3000/callback"]
  logout_urls   = ["http://localhost:3000/logout"]
}

resource "aws_cognito_user_pool_domain" "cloud_balance_domain" {
  domain       = "cloud-balance-${random_id.domain_suffix.hex}"
  user_pool_id = aws_cognito_user_pool.cloud_balance_user_pool.id
}

resource "random_id" "domain_suffix" {
  byte_length = 4
}

# Attach Cognito Authorizer to API Gateway
resource "aws_apigatewayv2_authorizer" "cognito_authorizer" {
  api_id           = aws_apigatewayv2_api.http_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.cloud_balance_client.id]
    issuer   = "https://${aws_cognito_user_pool.cloud_balance_user_pool.endpoint}"
  }

  name = "CognitoAuthorizer"
}

resource "aws_apigatewayv2_route" "root_route" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "ANY /{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_authorizer.id
}

# Output the Variables for Access
output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "rds_endpoint" {
  value = aws_db_instance.cloud_balance_db.endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.cloud_balance_user_pool.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.cloud_balance_client.id
}

output "cognito_user_pool_domain" {
  value = aws_cognito_user_pool_domain.cloud_balance_domain.domain
}

# NAT Gateway for access to fetch Lambda
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "cloud-balance-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = "subnet-0aad0b120e1ecf4e6"
  tags = {
    Name = "cloud-balance-nat-gateway"
  }
}

resource "aws_route_table" "private_rt" {
  vpc_id = "vpc-0e64c10620ffbf014"
  tags = {
    Name = "cloud-balance-private-rt"
  }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = "vpc-0e64c10620ffbf014"
}

resource "aws_route_table" "public_rt" {
  vpc_id = "vpc-0e64c10620ffbf014"
}

resource "aws_route" "public_subnet_to_igw" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Associate private subnets with private route table (so they can use NAT)
resource "aws_route_table_association" "private_subnet_1_association" {
  subnet_id      = "subnet-05f8962b75a12010c" # private subnet
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = "subnet-0aad0b120e1ecf4e6" # NAT gateway's subnet
  route_table_id = aws_route_table.public_rt.id
}
