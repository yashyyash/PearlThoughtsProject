# Define the provider
provider "aws" {
  region = "us-east-1" # Update with your preferred region
}

# Define your VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Data source to get availability zones
data "aws_availability_zones" "available" {}

# Define multiple subnets in different Availability Zones
resource "aws_subnet" "main" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)  # Unique CIDR for each subnet
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
}

# Define an Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Define a route table to route traffic to the Internet Gateway
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
}

# Define a route to the Internet Gateway
resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate the route table with the subnets
resource "aws_route_table_association" "subnet_association" {
  count          = 2
  subnet_id      = element(aws_subnet.main.*.id, count.index)
  route_table_id = aws_route_table.main.id
}

# Define a security group
resource "aws_security_group" "ecs_sg" {
  vpc_id = aws_vpc.main.id
}

# Define an ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "medusa-cluster"
}

# Define an IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
}

# Attach policies to the IAM Role
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role     = aws_iam_role.ecs_task_execution_role.name
}

# Define an ECS Task Definition
resource "aws_ecs_task_definition" "medusa_task" {
  family                = "medusa-task"
  execution_role_arn    = aws_iam_role.ecs_task_execution_role.arn
  network_mode          = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu                   = "256"  # Added CPU at task level
  memory                = "512"  # Added Memory at task level

  container_definitions = jsonencode([{
    name      = "medusa-container"
    image     = "your-docker-image:latest" # Update with your Docker image
    memory    = 512
    cpu       = 256
    essential = true
    portMappings = [
      {
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
      },
    ]
  }])
}

# Define an ECS Service
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.main[*].id  # Use the IDs of the created subnets
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_target_group.arn
    container_name   = "medusa-container"
    container_port   = 8080
  }

  deployment_controller {
    type = "ECS"
  }

  tags = {
    Name = "medusa-service"
  }
}

# Define an Application Load Balancer (ALB)
resource "aws_lb" "medusa_alb" {
  name               = "medusa-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = aws_subnet.main[*].id # Use the IDs of the created subnets
}

# Define a Target Group for ALB
resource "aws_lb_target_group" "medusa_target_group" {
  name     = "medusa-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Ensure the target type is "ip" for awsvpc network mode
  target_type = "ip"
}

# Define a Listener for ALB
resource "aws_lb_listener" "medusa_listener" {
  load_balancer_arn = aws_lb.medusa_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.medusa_target_group.arn
  }
}
