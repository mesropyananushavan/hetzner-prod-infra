terraform {
  backend "s3" {
    bucket                      = "hetzner-prod-infra-tfstate"
    key                         = "prod/terraform.tfstate"
    region                      = "eu-central-1"
    endpoint                    = "https://fsn1.your-objectstorage.com"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
