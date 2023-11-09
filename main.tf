
provider "aws" {
  region = var.region
  access_key = var.aws_key
  secret_key = var.aws_secret
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "2.77.0"

  name                 = "orderserviceapp"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  public_subnets       = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "orderselfservice_public" {
  count                   = 2
  cidr_block              = module.vpc.vpc_cidr_block
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "orderselfservice_private" {
  count             = 2
  cidr_block        = module.vpc.vpc_cidr_block
  vpc_id            = module.vpc.vpc_id
}

resource "aws_security_group" "app" {
  name   = "orderservice_app"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "orderservice_app"
  }
}

resource "aws_internet_gateway" "gateway" {
  vpc_id = module.vpc.vpc_id
}

resource "aws_route" "internet_access" {
  route_table_id         = module.vpc.default_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}

resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.orderselfservice_public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
  depends_on    = [aws_internet_gateway.gateway]
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = module.vpc.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.orderselfservice_private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_security_group" "lb" {
  name        = "orderselfserviceapp-security-group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "default" {
  name            = "orderselfservice-lb"
  subnets         = [for subnet in aws_subnet.orderselfservice_public : subnet.id]
  security_groups = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "orderselfserviceapp" {
  name        = "orderselfservice-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"
}

resource "aws_lb_listener" "orderselfserviceapp" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.orderselfserviceapp.id
    type             = "forward"
  }
}

resource "aws_ecs_task_definition" "orderselfservice" {
  family                   = "orderselfservice-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "public.ecr.aws/r1c1n5k9/wyk-order-self-service-app:latest",
    "cpu": 1024,
    "memory": 2048,
    "name": "orderselfservice-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 8080,
        "hostPort": 8080
      }
    ]
  }
]
DEFINITION
}

resource "aws_security_group" "orderselfservice_task" {
  name        = "orderselfservice-task-security-group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "example-cluster"
}

resource "aws_ecs_service" "orderselfservice" {
  name            = "orderselfservice-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.orderselfservice.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.orderselfservice_task.id]
    subnets         = [for subnet in aws_subnet.orderselfservice_public : subnet.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.orderselfserviceapp.id
    container_name   = "orderselfservice-app"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.orderselfserviceapp]
}