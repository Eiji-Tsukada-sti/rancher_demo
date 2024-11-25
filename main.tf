provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    "Name" = "${var.prefix}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

data "aws_availability_zones" "available" {

}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 8, count.index)
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    "Name" = "${var.prefix}-public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table_association" "public_subnet_assoc" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "instance_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 2379
    to_port   = 2380
    protocol  = "tcp"
    self      = true
    description = "etcd"
  }

  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
    description = "Canal/Flannel VXLAN overlay networking"
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kubernetes API"
  }

  ingress {
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "RKE2 Supervisor API"
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
    description = "kubelet"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "NodePort port range"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "tls_private_key" "instance_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "instance_key" {
  key_name   = "rancher_demo_instance_key"
  public_key = tls_private_key.instance_key.public_key_openssh
}

# ローカル環境にインスタンス接続用のpemキーを作成
resource "local_file" "private_key_pem" {
  filename        = "rancher_demo_instance_key.pem"
  content         = tls_private_key.instance_key.private_key_pem
  file_permission = "0600"
}

resource "aws_instance" "control_plane" {
  count                       = 3
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[count.index].id
  security_groups             = [aws_security_group.instance_sg.id]
  key_name                    = aws_key_pair.instance_key.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
  }

  tags = {
    "Name" = "${var.prefix}-rke2-control-plane-${count.index + 1}"
  }
}

resource "aws_lb" "nlb" {
  name                             = "${var.prefix}-nlb"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = [for subnet in aws_subnet.public : subnet.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "rancher_80_tg" {
  name     = "${var.prefix}-http-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rancher_80_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "rancher_80_attach" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rancher_80_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 80
}

resource "aws_lb_target_group" "rancher_443_tg" {
  name     = "${var.prefix}-https-tg"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc.id
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rancher_443_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "rancher_443_attach" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rancher_443_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 443
}

output "isntance_public_ips" {
  value = aws_instance.control_plane[*].public_ip
}

output "initial_server_public_ip" {
  value = aws_instance.control_plane[0].public_ip
}

output "nlb_dns_name" {
  value = aws_lb.nlb.dns_name
}
