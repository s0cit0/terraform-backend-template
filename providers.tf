provider "aws" {
  region = "us-east-1" # change if needed

  default_tags {
    tags = {
      owner = "MLR"
    }
  }
}
