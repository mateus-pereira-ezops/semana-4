terraform {
  backend "s3" {
    bucket       = "mateus-pereira-lambda-artifacts"
    key          = "dev/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
