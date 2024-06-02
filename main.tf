
# Busca os ids dos AZ #

data "aws_availability_zones" "available" {
  state = "available"
}


# Módulo VPC #
#tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "main-vpc"
  cidr = "10.0.0.0/16"

  azs             = data.aws_availability_zones.available.names
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true
  external_nat_ip_ids  = aws_eip.nat.*.id



}

# Security Group LB #
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
#tfsec:ignore:aws-ec2-no-public-egress-sgr
resource "aws_security_group" "app_lb" {
  name        = "http"
  description = "Allow inbound HTTP traffic"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Liberado porta lb http"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Liberado outbound para internet"
  }

  vpc_id = module.vpc.vpc_id
}



# Security Group instancias #
#tfsec:ignore:aws-ec2-no-public-egress-sgr
#tfsec:ignore:aws-ec2-no-public-ingress-sgr
resource "aws_security_group" "sg_ec2" {
  name        = "http"
  description = "Allow inbound VPC traffic"

  ingress {
    description     = "HTTP From ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.app_lb.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Allow inbound SSH traffic"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "liberado Outbound para internet"
  }

  vpc_id = module.vpc.vpc_id
}


# Criação da instância modelo #
#tfsec:ignore:aws-ec2-enforce-launch-config-http-token-imds
resource "aws_launch_template" "teste" {
  name_prefix   = "teste"
  image_id      = "ami-04b70fa74e45c3917"
  instance_type = "t2.micro"
  user_data     = filebase64("example.sh")
  key_name      = "linux-devops"


  iam_instance_profile {
    arn = "arn:aws:iam:::instance-profile/EC2_SSM_FULL_ACCESS"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = 8
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.sg_ec2.id]

  }


  tags = {
    Name = "AppScalling"
  }


}

# Criação do autoscaling  #

resource "aws_autoscaling_group" "bar" {
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  force_delete        = true
  capacity_rebalance  = true
  vpc_zone_identifier = module.vpc.private_subnets
  health_check_type   = "ELB"


  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 10
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.teste.id
        version            = "$Latest"
      }
    }


  }
  tag {
    key                 = "Name"
    value               = "ASG web server"
    propagate_at_launch = true
  }


  lifecycle {
    ignore_changes = [desired_capacity, target_group_arns]
  }



}



#  ALB das instâncias #
#tfsec:ignore:aws-elb-alb-not-public
#tfsec:ignore:aws-elb-drop-invalid-headers
resource "aws_lb" "app" {
  name               = "learn-asg-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.app_lb.id]
  subnets            = module.vpc.public_subnets
}

# target group das instâncias #

resource "aws_lb_target_group" "app" {
  name     = "app-asg-lb"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}


# Listener da porta 80 #

#tfsec:ignore:aws-elb-http-not-used
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

}


# Atachar o autoscalling no target group #

resource "aws_autoscaling_attachment" "app" {
  autoscaling_group_name = aws_autoscaling_group.bar.id
  lb_target_group_arn    = aws_lb_target_group.app.arn
}


resource "aws_eip" "nat" {
  count = 1
  vpc   = true
}