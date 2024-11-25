variable "aws_region" {
  default = "us-east-1"
}

variable "prefix" {
  default = "rancher-demo"
}

variable "ami" {
  default = "ami-0866a3c8686eaeeba"
  description = "Ubuntu 24.04 LTS"
}

variable "instance_type" {
  default = "t3.xlarge"
}

variable "token" {
  default = "my-shared-secret"
}
