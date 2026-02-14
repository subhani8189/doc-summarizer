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
  # If you get "Collection already exists" errors, change v3 to v4
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
  name = "${local.collection_name}-encryption"
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]
    AWSOwnedKey = true
  })
}

# Network Policy
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.collection_name}-network"
  type = "network"

  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }, {
      ResourceType = "dashboard"
      Resource     = ["collection/${local.collection_name}"]
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
# Defines WHAT the role can do inside the collection (Index/Read/Write)
resource "aws_opensearchserverless_access_policy" "data_access" {
  name = "${local.collection_name}-access"
  type = "data"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      # Using local variable to avoid race conditions
      Resource   = ["collection/${local.collection_name}"]
      Permission = [
        "aoss:CreateCollectionItems",
        "aoss:DeleteCollectionItems",
        "aoss:UpdateCollectionItems",
        "aoss:DescribeCollectionItems"
      ]
    }, {
      ResourceType = "index"
      Resource     = ["index/${local.collection_name}/*"]
      Permission   = [
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
  name = "summarizer_lambda_role_v3"

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
      # 1. Allow Access to S3
      {
        Action   = ["s3:GetObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.doc_bucket.arn}/*"
      },
      # 2. Allow Access to Bedrock (Claude 3 Sonnet)
      {
        Action   = ["bedrock:InvokeModel"]
        Effect   = "Allow"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
      },
      # 3. Allow Access to OpenSearch Serverless API (CRITICAL FIX)
      {
        Action   = ["aoss:APIAccessAll"]
        Effect   = "Allow"
        Resource = "*" 
      },
      # 4. Allow Logging
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
  source_dir  = "../src" # Ensure your python file is in a folder named 'src' one level up
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
  
  # FIX: Commented out to prevent "UnreservedConcurrentExecution" error
  # reserved_concurrent_executions = 1

  environment {
    variables = {
      # Pass the endpoint without the https:// prefix
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

output "opensearch_endpoint" {
  value = aws_opensearchserverless_collection.search_collection.collection_endpoint
}
