# Define the AWS provider and specify the region
provider "aws" {
  region = "us-east-1" # Set your preferred AWS region
}

# Define the Virtual Private Cloud (VPC) resource
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # CIDR block for the VPC; defines the IP address range
}

# Data source to retrieve the list of available Availability Zones in the region
data "aws_availability_zones" "available" {}

# Define multiple subnets within the VPC, each in a different Availability Zone
resource "aws_subnet" "main" {
  count = 2 # Number of subnets to create
  vpc_id = aws_vpc.main.id # Associate the subnet with the previously defined VPC
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)  # Calculate unique CIDR block for each subnet
  availability_zone = element(data.aws_availability_zones.available.names, count.index) # Assign each subnet to an Availability Zone
}

# Define an Internet Gateway for the VPC to allow external internet access
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id # Attach the Internet Gateway to the VPC
}

# Define a route table to manage the routing of network traffic
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id # Associate the route table with the VPC
}

# Define a route to direct all outbound traffic to the Internet Gateway
resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.main.id # Route table to add the route to
  destination_cidr_block = "0.0.0.0/0" # Route all traffic to the Internet
  gateway_id             = aws_internet_gateway.main.id # Specify the Internet Gateway as the target
}

# Associate the route table with the subnets so they can use the defined routes
resource "aws_route_table_association" "subnet_association" {
  count          = 2 # Number of route table associations to create
  subnet_id      = element(aws_subnet.main.*.id, count.index) # Select each subnet by index
  route_table_id = aws_route_table.main.id # Associate the route table with each subnet
}

# Define a security group for ECS tasks to control inbound and outbound traffic
resource "aws_security_group" "ecs_sg" {
  vpc_id = aws_vpc.main.id # Associate the security group with the VPC
}

# Define an ECS Cluster to manage a group of ECS services and tasks
resource "aws_ecs_cluster" "main" {
  name = "medusa-cluster" # Name of the ECS cluster
}

# Define an IAM Role for ECS Task Execution with appropriate permissions
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole" # Name of the IAM Role

  assume_role_policy = jsonencode({
    Version = "2012-10-17" # IAM policy version
    Statement = [
      {
        Action = "sts:AssumeRole", # Action allowed for this role
        Effect = "Allow", # Allow this action
        Principal = {
          Service = "ecs-tasks.amazonaws.com" # Principal service allowed to assume the role
        }
      },
    ]
  })
}

# Attach the ECS Task Execution Policy to the IAM Role to grant necessary permissions
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # ARN of the policy to attach
  role     = aws_iam_role.ecs_task_execution_role.name # Role to attach the policy to
}

# Define an ECS Task Definition which specifies how the container should run
resource "aws_ecs_task_definition" "medusa_task" {
  family                = "medusa-task" # Family name for the task definition
  execution_role_arn    = aws_iam_role.ecs_task_execution_role.arn # Role for task execution
  network_mode          = "awsvpc" # Network mode for the task
  requires_compatibilities = ["FARGATE"] # Specify Fargate launch type

  cpu                   = "256"  # CPU units allocated to the task
  memory                = "512"  # Memory (in MiB) allocated to the task

  # Container definitions specify the container details
  container_definitions = jsonencode([{
    name      = "medusa-container" # Name of the container
    image     = "your-docker-image:latest" # Docker image to use; update with your image
    memory    = 512 # Memory (in MiB) allocated to the container
    cpu       = 256 # CPU units allocated to the container
    essential = true # Mark the container as essential for the task
    portMappings = [
      {
        containerPort = 8080 # Port on which the container will listen
        hostPort      = 8080 # Port on the host to map to the container port
        protocol      = "tcp" # Protocol for communication
      },
    ]
  }])
}

# Define an ECS Service to run and manage the tasks defined by the task definition
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service" # Name of the ECS service
  cluster         = aws_ecs_cluster.main.id # ECS cluster where the service will run
  task_definition = aws_ecs_task_definition.medusa_task.arn # Task definition to use
  desired_count   = 1 # Desired number of task instances to run
  launch_type     = "FARGATE" # Launch type for the service

  # Network configuration for the service
  network_configuration {
    subnets          = aws_subnet.main[*].id  # List of subnet IDs for the service
    assign_public_ip = true # Assign a public IP to the tasks
    security_groups  = [aws_security_group.ecs_sg.id] # Security group to apply to the tasks
  }

  # Load balancer configuration to distribute traffic to the containers
  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_target_group.arn # Target group for the load balancer
    container_name   = "medusa-container" # Name of the container in the task definition
    container_port   = 8080 # Port on the container to map for the load balancer
  }

  # Deployment controller for managing service deployments
  deployment_controller {
    type = "ECS" # Use ECS deployment controller
  }

  tags = {
    Name = "medusa-service" # Tag for identifying the service
  }
}

# Define an Application Load Balancer (ALB) to distribute incoming traffic to the ECS service
resource "aws_lb" "medusa_alb" {
  name               = "medusa-alb" # Name of the load balancer
  internal           = false # Set to false to make the ALB internet-facing
  load_balancer_type = "application" # ALB type
  security_groups    = [aws_security_group.ecs_sg.id] # Security group to apply to the ALB
  subnets            = aws_subnet.main[*].id # Subnets where the ALB will be deployed
}

# Define a Target Group for the ALB to route requests to the ECS tasks
resource "aws_lb_target_group" "medusa_target_group" {
  name     = "medusa-targe
