# ==============================================================================
# 1. NETWORKING TIER (VPC, Subnets, Routing)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "3tier-vpc-af-south-1" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "3tier-igw" }
}

# --- Availability Zone af-south-1a ---
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "af-south-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "pub-subnet-1" }
}

resource "aws_subnet" "private_app_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "af-south-1a"
  tags              = { Name = "priv-app-subnet-1" }
}

resource "aws_subnet" "private_db_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "af-south-1a"
  tags              = { Name = "priv-db-subnet-1" }
}

# --- Availability Zone af-south-1b (Required for RDS Multi-AZ Subnet Rules) ---
resource "aws_subnet" "private_db_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "af-south-1b"
  tags              = { Name = "priv-db-subnet-2" }
}

# --- Public Route Table & Association ---
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-route-table" }
}

resource "aws_route_table_association" "public_1_assoc" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

# ==============================================================================
# 2. SECURITY GROUPS
# ==============================================================================

# Web Tier: Open to the Internet
resource "aws_security_group" "web_sg" {
  name   = "web-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# App Tier: Accessible only from Web Tier
resource "aws_security_group" "app_sg" {
  name   = "app-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 8080 # Assuming your backend app runs on port 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DB Tier: Accessible only from App Tier
resource "aws_security_group" "db_sg" {
  name   = "db-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# 3. COMPUTE TIER (Web & App EC2 Instances)
# ==============================================================================

# Amazon Linux 2023 AMI lookup for af-south-1
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_instance" "web_server" {
  ami                    = data.aws_ami.amazon_linux.id
  # Infracost demo: large jump vs main (t3.large) so PR comment shows $ delta
  instance_type          = "m5.4xlarge"
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  ebs_block_device {
    device_name = "/dev/sdf"
    volume_type = "io1"
    volume_size = 3000
    iops        = 1500
  }

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from the Web Tier (af-south-1a)</h1>" > /var/www/html/index.html
              EOF

  tags = { Name = "3tier-web-server" }
}

resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux.id
  # Infracost demo: bump vs main (t3.medium)
  instance_type          = "m5.2xlarge"
  subnet_id              = aws_subnet.private_app_1.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tags = { Name = "3tier-app-server" }
}

# ==============================================================================
# 3b. EXTRA COSTED RESOURCES (Infracost PR summary demo)
# ==============================================================================

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "3tier-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id
  tags          = { Name = "3tier-nat" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.5.0/24"
  availability_zone       = "af-south-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "pub-subnet-2" }
}

resource "aws_route_table_association" "public_2_assoc" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_lb" "web" {
  name               = "3tier-web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  tags               = { Name = "3tier-web-alb" }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "3tier-redis-subnets"
  subnet_ids = [aws_subnet.private_app_1.id, aws_subnet.private_db_2.id]
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "3tier-redis"
  engine               = "redis"
  node_type            = "cache.m5.large"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.app_sg.id]
}

resource "aws_ebs_volume" "app_data" {
  availability_zone = "af-south-1a"
  size              = 500
  type              = "gp3"
  iops              = 3000
  throughput        = 250
  tags              = { Name = "3tier-app-data" }
}

resource "aws_instance" "worker" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "m5.xlarge"
  subnet_id              = aws_subnet.private_app_1.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  tags                   = { Name = "3tier-worker" }
}

# ==============================================================================
# 4. DATA TIER (Amazon RDS MySQL)
# ==============================================================================

resource "aws_db_subnet_group" "db_subnets" {
  name       = "main-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id] # Fixed: Now passes two AZ subnets
}

resource "aws_db_instance" "database" {
  identifier             = "tier3-db"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  # Infracost demo: bump vs main (db.t3.small)
  instance_class         = "db.m5.large"
  db_name                = "webappdb"
  username               = "adminuser"
  password               = var.db_password # Fixed: Uses a secure variable input
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id] # Linked security group
  skip_final_snapshot    = true
  multi_az               = false
}

# ==============================================================================
# 5. VARIABLES & OUTPUTS
# ==============================================================================

variable "db_password" {
  type        = string
  description = "The database admin password"
  sensitive   = true
}

output "web_public_ip" {
  value       = aws_instance.web_server.public_ip
  description = "The public IP address of the web server to test in your browser"
}
