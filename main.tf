provider "aws" {
  region = "us-east-1"
}

# IAM Role for Lambda Execution
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
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

# Security Group for RDS (initially without inbound rules)
resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Allow PostgreSQL access"
  vpc_id      = "vpc-0e64c10620ffbf014"
}

# Security Group for Lambda (initially without egress rules)
resource "aws_security_group" "lambda_sg" {
  name        = "lambda-security-group"
  description = "Allow Lambda to access RDS"
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

# Lambda Egress Rule to Allow Access to RDS
resource "aws_security_group_rule" "lambda_egress" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda_sg.id
  source_security_group_id = aws_security_group.rds_sg.id
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

  vpc_config {
  subnet_ids         = ["subnet-0aad0b120e1ecf4e6", "subnet-05f8962b75a12010c"] # Add correct subnet IDs
  security_group_ids = [aws_security_group.lambda_sg.id]
}

environment {
  variables = {
    DATABASE_URL = "postgres://testuser:testpassword@${aws_db_instance.cloud_balance_db.endpoint}/cloud_balance_db"
    BASE_PATH    = "/dev"
    NODE_ENV     = "production" 
  }
}
}

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

resource "aws_apigatewayv2_route" "root_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backend_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Create Cognito User Pool
#resource "aws_cognito_user_pool" "cloud_balance_user_pool" {
#  name = "cloud_balance_user_pool"
#}

#resource "aws_cognito_user_pool_client" "cloud_balance_client" {
#  name         = "cloud_balance_client"
#  user_pool_id = aws_cognito_user_pool.cloud_balance_user_pool.id
#  generate_secret = false
#  explicit_auth_flows = [
#    "ALLOW_USER_PASSWORD_AUTH",
#    "ALLOW_REFRESH_TOKEN_AUTH",
#    "ALLOW_USER_SRP_AUTH"
#  ]
#}

#resource "aws_cognito_user_pool_domain" "cloud_balance_domain" {
#  domain      = "cloud-balance-${random_id.domain_suffix.hex}"
#  user_pool_id = aws_cognito_user_pool.cloud_balance_user_pool.id
#}

#resource "random_id" "domain_suffix" {
#  byte_length = 4
#}

# Attach Cognito Authorizer to API Gateway
#resource "aws_apigatewayv2_authorizer" "cognito_authorizer" {
#  api_id        = aws_apigatewayv2_api.http_api.id
#  authorizer_type = "JWT"
#  identity_sources = ["$request.header.Authorization"]
  
#  jwt_configuration {
#    audience = [aws_cognito_user_pool_client.cloud_balance_client.id]
#    issuer   = aws_cognito_user_pool.cloud_balance_user_pool.endpoint
#  }
#
#  name = "CognitoAuthorizer"
#}

#resource "aws_apigatewayv2_route" "root_route" {
#  api_id             = aws_apigatewayv2_api.http_api.id
#  route_key          = "ANY /{proxy+}"
#  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
#  authorization_type = "JWT"
#  authorizer_id      = aws_apigatewayv2_authorizer.cognito_authorizer.id
#}

# Output the Variables for Access
output "api_gateway_url" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "rds_endpoint" {
  value = aws_db_instance.cloud_balance_db.endpoint
}

# To Output the Cognito Variables
#output "cognito_user_pool_id" {
#  value = aws_cognito_user_pool.cloud_balance_user_pool.id
#}

#output "cognito_user_pool_client_id" {
#  value = aws_cognito_user_pool_client.cloud_balance_client.id
#}

#output "cognito_user_pool_domain" {
#  value = aws_cognito_user_pool_domain.cloud_balance_domain.domain
#}
