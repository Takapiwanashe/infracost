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
  # Bumped for Infracost PR cost-diff demo (was t3.micro)
  instance_type          = "t3.large"
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

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
  # Bumped for Infracost PR cost-diff demo (was t3.micro)
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private_app_1.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tags = { Name = "3tier-app-server" }
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
  # Bumped for Infracost PR cost-diff demo (was db.t3.micro)
  instance_class         = "db.t3.small"
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
