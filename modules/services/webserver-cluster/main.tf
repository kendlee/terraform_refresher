terraform {
  backend "s3" {
    bucket         = "ns-kelee-terraform-tutorial"
    key            = "stage/services/webserver-cluster/terraform.tfstate"
    region         = "ap-northeast-1"

    dynamodb_table = "simple-server-locks"
    encrypt        = true
  }
}

locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = "0.0.0.0/0"
}

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "ap-northeast-1"
  }
}

resource "aws_security_group" "server_secgroup" {
  name = "${var.cluster_name}-server-secgroup"
  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = local.tcp_protocol
    cidr_blocks = [local.all_ips]
  }
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data.sh")

  vars = {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }
}

resource "aws_launch_configuration" "server_config" {
  image_id        = "ami-0278fe6949f6b1a06"
  instance_type   = var.instance_type
  security_groups = [aws_security_group.server_secgroup.id]

  user_data = data.template_file.user_data.rendered

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_autoscaling_group" "server_asg" {
  launch_configuration = aws_launch_configuration.server_config.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids

  target_group_arns = [aws_lb_target_group.server_asg.arn]
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-simple-server-asg"
    propagate_at_launch = true
  }
}

resource "aws_lb" "server_lb" {
  name               = "${var.cluster_name}-simple-server-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default.ids
  security_groups    = [aws_security_group.alb_secgroup.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.server_lb.arn
  port              = local.http_port
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_security_group" "alb_secgroup" {
  name = "${var.cluster_name}-simple-server-alb-secgroup"
  ingress {
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = [local.all_ips]
  }

  egress {
    from_port  = local.any_port
    to_port    = local.any_port
    protocol   = local.any_protocol
    cidr_blocks = [local.all_ips]
  }
}

resource "aws_lb_target_group" "server_asg" {
  name = "${var.cluster_name}-simple-server-asg"
  port = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "server_lb" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type  = "forward"
    target_group_arn = aws_lb_target_group.server_asg.arn
  }
}