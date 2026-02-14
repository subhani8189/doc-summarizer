terraform {
  backend "s3" {
    bucket = "subhani9394" # REPLACE with the bucket name from Phase 1, Step 2
    key    = "doc-summarizer/terraform.tfstate"
    region = "us-east-1"
  }
}