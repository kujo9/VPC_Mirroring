variable "aws_region" {
  default = "us-west-2"
}

variable "list" {
  default = ["requester_vpc", "accepter_vpc"]
}

variable "map" {
  default = {
    requester_vpc = "10.0.0.0/18"
    accepter_vpc  = "10.1.0.0/18"
  }
}
provider "aws" {
  region = var.aws_region
}
//3. Random String for Naming:
resource "random_string" "random_name" {
  length  = 10
  special = false
  upper   = false
}
#4. VPC Creation:
resource "aws_vpc" "create_vpc" {
  count      = length(var.list)
  cidr_block = lookup(var.map, element(var.list, count.index))
  tags = {
    Name = var.list[count.index]
  }
}
#5. VPC Peering Connection:
resource "aws_vpc_peering_connection" "just_peer" {
  vpc_id      = aws_vpc.create_vpc[0].id
  peer_vpc_id = aws_vpc.create_vpc[1].id
  auto_accept = true
  tags = {
    Name = "just_peer"
  }
  depends_on = [aws_vpc.create_vpc]
}
#6. Subnet Creation for Requester VPC:
resource "aws_subnet" "create_subnet" {
  availability_zone       =  "us-west-2a" 
  vpc_id                  = aws_vpc.create_vpc[0].id
  map_public_ip_on_launch = "true" 
  cidr_block              = "10.0.0.0/20"
  tags = {
    Name =  "application_public_subnet" 
  }
}
#7. Subnet Creation for Accepter VPC:
resource "aws_subnet" "create_subnet1" {
  count                   = length(var.list)
  availability_zone       = count.index == 0 ? "us-west-2a" : "us-west-2b"
  vpc_id                  = aws_vpc.create_vpc[1].id
  map_public_ip_on_launch = count.index == 0 ? "true" : "false"
  cidr_block              = "10.1.${count.index}.0/28"
  tags = {
    Name = "${count.index == 0 ? "database_public_subnet" : "database_private_subnet"}"
  }
}
#8. Internet Gateway for Public Subnets:
resource "aws_internet_gateway" "requester_igw" {
  count  = length(var.list)
  vpc_id = element(aws_vpc.create_vpc.*.id, count.index)
  tags = {
    Name = "requester_igw"
  }
}
#9. NAT Gateway for Private Subnet in Accepter VPC:
resource "aws_eip" "nat_gateway" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_gateway.id
  subnet_id     = aws_subnet.create_subnet1[0].id
  depends_on    = [aws_internet_gateway.requester_igw]
  tags = {
    Name = "nat_gateway"
  }
}
#10. Route Table for Requester VPC:
resource "aws_route_table" "requester_rt" {
  vpc_id = aws_vpc.create_vpc[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.requester_igw[0].id
  }
  route {
    cidr_block                = "10.1.0.0/28"
    vpc_peering_connection_id = aws_vpc_peering_connection.just_peer.id
  }
  route {
 cidr_block                = "10.1.1.0/28"
    vpc_peering_connection_id = aws_vpc_peering_connection.just_peer.id
  }

  depends_on = [aws_vpc_peering_connection.just_peer, aws_internet_gateway.requester_igw, aws_nat_gateway.nat_gateway]
  tags = {
    Name = "requester_routetable"
  }
}
#11. Associating Route Table with Public Subnet in Requester VPC:
resource "aws_route_table_association" "requester_rt_association" {
  subnet_id      = aws_subnet.create_subnet.id
  route_table_id = aws_route_table.requester_rt.id
}
#12. Route Table for Public Subnet in Accepter VPC:
resource "aws_route_table" "public_accepter_rt" {
  vpc_id = aws_vpc.create_vpc[1].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.requester_igw[1].id
  }
  route {
    cidr_block                = "10.0.0.0/20"
    vpc_peering_connection_id = aws_vpc_peering_connection.just_peer.id
  }
  depends_on = [aws_vpc_peering_connection.just_peer]
  tags = {
    Name = "public_accepter_routetable"
  }
}
#13. Associating Route Table with Private Subnet in Accepter VPC:
resource "aws_route_table_association" "public_accepter_rt_association" {
  subnet_id      = aws_subnet.create_subnet1[0].id
  route_table_id = aws_route_table.public_accepter_rt.id
}
#14. Route Table for Private Subnet in Accepter VPC:
resource "aws_route_table" "private_accepter_rt" {
  vpc_id = aws_vpc.create_vpc[1].id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
  route {
    cidr_block                = "10.0.0.0/20"
    vpc_peering_connection_id = aws_vpc_peering_connection.just_peer.id
  }
  depends_on = [aws_vpc_peering_connection.just_peer]
  tags = {
    Name = "private_accepter_routetable"
  }
}
#15. Associating Route Table with Private Subnet in Accepter VPC:
resource "aws_route_table_association" "private_accepter_rt_association" {
  subnet_id      = aws_subnet.create_subnet1[1].id
  route_table_id = aws_route_table.private_accepter_rt.id
}
#16. Security Groups for Instances:
resource "aws_security_group" "create_sg" {
  count       = 2
  name        = count.index == 0 ? "requester_sg" : "accepter_sg"
  description = "allowing only SSH to connect with EC2 and then connect to another EC2 in the private VPC"
  vpc_id      = aws_vpc.create_vpc[count.index].id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [count.index == 0 ? "0.0.0.0/0" : "10.${count.index - 1}.0.0/20"]
  }
  ingress {
    from_port   = 8
    to_port     = 0
    protocol    = "icmp"
    cidr_blocks = [count.index == 0 ? "0.0.0.0/0" : "10.${count.index - 1}.0.0/20"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${count.index == 0 ? "requester_sg" : "accepter_sg"}"
  }
}
#17. Security Group for Public Instances:
resource "aws_security_group" "create_sg1" {
  name        = "public_instance_sg" 
  description = "allowing only SSH to connect with EC2 and then connect to another EC2 in the same VPC"
  vpc_id      = aws_vpc.create_vpc[1].id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "bastion_host_sg"
  }
}
#18. Security Group for Private Instances:
resource "aws_security_group" "create_sg2" {
  name        = "private_instance_sg"
  description = "allowing only SSH to connect with EC2 and then connect to another EC2 in the same VPC"
  vpc_id      = aws_vpc.create_vpc[1].id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/28","10.0.0.0/20"]
  }
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.1.0.0/28","10.0.0.0/20"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "database_accepter_sg"
  }
}
//19. Generating Key Pair for Application:
resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "application_key"
  public_key = tls_private_key.example.public_key_openssh
}
//20. Generating Key Pair for Database:
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh" {
  key_name   = "database_key"
  public_key = tls_private_key.ssh.public_key_openssh
}
#21. Launching Application Instance:
resource "aws_instance" "app_create_inst" {
  instance_type   = "t3a.nano"
  ami             = "ami-03d5c68bab01f3496"
  key_name        = "${aws_key_pair.generated_key.key_name}" 
  subnet_id       = aws_subnet.create_subnet.id
  security_groups = [aws_security_group.create_sg[0].id]
  tags = {
    Name =  "app_public_inst" 
  }
}
#22. Launching Database Instances:
resource "aws_instance" "database_create_inst" {
  instance_type   = "t2.micro"
  ami             = "ami-03d5c68bab01f3496"
  key_name        =  "${aws_key_pair.ssh.key_name}"
  subnet_id       = aws_subnet.create_subnet1[0].id
  security_groups = ["${aws_security_group.create_sg1.id}"] 
  user_data       = file("/root/advanced-vpc/vpc-mirroring/startup-script.sh")
  tags = {
    Name =  "suricata_public_inst" 
  }
}
#23-29. Setting up Traffic Mirroring for Instances:
#Mirror Target
resource "aws_ec2_traffic_mirror_target" "eni" {
  description          = "ENI target"
  network_interface_id = aws_instance.database_create_inst.primary_network_interface_id
}

resource "aws_ec2_traffic_mirror_filter" "filter" {
  description      = "traffic mirror filter - terraform example"
  network_services = ["amazon-dns"]
}

#Mirror Filter
resource "aws_ec2_traffic_mirror_filter_rule" "ruleout" {
  description              = "test rule"
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.filter.id
  destination_cidr_block   = "0.0.0.0/0"
  source_cidr_block        = "0.0.0.0/0"
  rule_number              = 1
  rule_action              = "accept"
  traffic_direction        = "egress"
   protocol                 = 0
}

resource "aws_ec2_traffic_mirror_filter_rule" "rulein" {
  description              = "test rule"
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.filter.id
  destination_cidr_block   = "0.0.0.0/0"
  source_cidr_block        = "0.0.0.0/0"
  rule_number              = 1
  rule_action              = "accept"
  traffic_direction        = "ingress"
  protocol                 = 0
}

#Mirror session
resource "aws_ec2_traffic_mirror_session" "session" {
  description              = "traffic mirror session - terraform example"
  network_interface_id     = aws_instance.app_create_inst.primary_network_interface_id
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.filter.id
  traffic_mirror_target_id = aws_ec2_traffic_mirror_target.eni.id
  session_number           = 1 
}
#30-32. Creating Local Files for Generated Keys:
resource "local_file" "aws_key" {
  content  = tls_private_key.example.private_key_pem
  filename = "application.pem"
}

resource "local_file" "aws_key1" {
  content  = tls_private_key.ssh.private_key_pem
  filename = "suricata.pem"
}
#33. Outputting Information:
output "ServersInfo" {
  value = {
    Application_Public_IP = aws_instance.app_create_inst.public_ip
    Suricata_IP           = aws_instance.database_create_inst.public_ip
  }
}