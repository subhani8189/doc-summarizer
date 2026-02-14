terraform {
  backend "s3" {
    bucket = "doc-summarizer-upload-20260214103915828700000001" # REPLACE with the bucket name from Phase 1, Step 2
    key    = "doc-summarizer/terraform.tfstate"
    region = "us-east-1"
  }
}
