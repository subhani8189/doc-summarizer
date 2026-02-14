terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- 0. Shared Locals ---
locals {
  # Change this to v3 or v4 if you still get "Already Exists" errors
  collection_name = "doc-summaries-v3"
}

# --- 1. S3 Bucket for Documents ---
resource "aws_s3_bucket" "doc_bucket" {
  bucket_prefix = "doc-summarizer-upload-"
  force_destroy = true
}

# --- 2. OpenSearch Serverless Policies (MUST BE CREATED FIRST) ---

# Encryption Policy
resource "aws_opensearchserverless_security_policy" "encryption" {
  name        = "${local.collection_name}-encryption"
  type        = "encryption"
  
  policy      = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource = ["collection/${local.collection_name}"]
    }]
    AWSOwnedKey = true
  })
}

# Network Policy
resource "aws_opensearchserverless_security_policy" "network" {
  name        = "${local.collection_name}-network"
  type        = "network"

  policy      = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource = ["collection/${local.collection_name}"]
    }, {
      ResourceType = "dashboard"
      Resource = ["collection/${local.collection_name}"]
    }]
    AllowFromPublic = true
  }])
}

# --- 3. OpenSearch Serverless Collection ---
resource "aws_opensearchserverless_collection" "search_collection" {
  name = local.collection_name
  type = "SEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

# Data Access Policy
resource "aws_opensearchserverless_access_policy" "data_access" {
  name        = "${local.collection_name}-access"
  type        = "data"
  policy      = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource = ["collection/${aws_opensearchserverless_collection.search_collection.name}"]
      Permission = [
        "aoss:CreateCollectionItems",
        "aoss:DeleteCollectionItems",
        "aoss:UpdateCollectionItems",
        "aoss:DescribeCollectionItems"
      ]
    }, {
      ResourceType = "index"
      Resource = ["index/${aws_opensearchserverless_collection.search_collection.name}/*"]
      Permission = [
        "aoss:CreateIndex",
        "aoss:DeleteIndex",
        "aoss:UpdateIndex",
        "aoss:DescribeIndex",
        "aoss:ReadDocument",
        "aoss:WriteDocument"
      ]
    }]
    Principal = [aws_iam_role.lambda_exec.arn]
  }])
}

# --- 4. IAM Role for Lambda ---
resource "aws_iam_role" "lambda_exec" {
  name = "summarizer_lambda_role_v3" # Renamed to avoid conflicts

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Attach Permissions
resource "aws_iam_role_policy" "lambda_policy" {
  name = "summarizer_lambda_policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:GetObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.doc_bucket.arn}/*"
      },
      {
        Action   = ["bedrock:InvokeModel"]
        Effect   = "Allow"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- 5. Lambda Function ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "../src"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "summarizer" {
  filename         = "lambda_function.zip"
  function_name    = "DocSummarizer"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 60
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  # FIX: Limit concurrency to 1 to prevent "Too Many Tokens" errors
  reserved_concurrent_executions = 1

  environment {
    variables = {
      OPENSEARCH_HOST = replace(aws_opensearchserverless_collection.search_collection.collection_endpoint, "https://", "")
    }
  }
}

# --- 6. S3 Trigger ---
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.summarizer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.doc_bucket.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.doc_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.summarizer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".txt"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# --- 7. Output ---
output "s3_bucket_name" {
  value = aws_s3_bucket.doc_bucket.id
}
