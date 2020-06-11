# XXX TODO:
# certain tags should eventually be pulled from an agnostic key value store, we no longer have one (bring back consul?)
# legacy tags should be deprecated as they are determined to be not required.
# new tags should be added as they are determined to be required
# Mappings for accounts and ids, eventually the map data itself should be moved into a kv store
# Default base iam_roles, base groups (security groups, vpc_id etc) are managed by cloudinfra and mappings should be moved into a kv store

# If there are any questions about fundamental infrastructure related concerns please reach out to cloud-infrastructure@mdsol.com

provider "aws" {
  profile = "ec2-default"
  region  = var.region
}

data "aws_ami" "core-cis-ubuntu" {

  # Always use the most recent 16.04 CIS Amazon Machine Image 
  most_recent = true
  filter {
    name   = "name"
    values = ["mdsol-ubuntu-1604-cis-2020-*"]
  }

  owners = ["${var.aws_account["${var.infra_environment}"]}"] #TODO: aws account mapped based based on color via consul backend or some such
}

# SECURITY-GROUP based on current medsanalytics-sandbox
resource "aws_security_group" "infra_secgroup" {
  name        = "${var.project_name}-${var.project_environment}" 
  description = "${var.project_name}-${var.project_environment} default secgroup"
  vpc_id      = "${var.infra_vpc["${var.infra_environment}"]}" 

ingress {
    description = "All traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = "true"
  }
  ingress {
    description = "http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    self        = "true"
  }

  ingress {
    description = "https"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    self        = "true"
  }

  ingress {
    description = "unknown"
    from_port   = 8000
    to_port     = 9000
    protocol    = "tcp"
    self        = "true"
  }

  ingress {
    description = "unknown"
    from_port   = 8850
    to_port     = 8850
    protocol    = "tcp"
    self        = "true"
  }

  ingress {
    description = "unknown"
    from_port   = 27000
    to_port     = 27009
    protocol    = "tcp"
    self        = "true"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM ROLE 
# Create IAM Role (always attach cloudinfr-base)
# Currently, generated policies don't have tags
# we should probably change that
resource "aws_iam_role" "infra_role" {
  name = "${var.project_name}-${var.project_environment}" # may want to use name_prefix for blue/green at some point
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
POLICY
} #end aws_iam_role

data "aws_iam_policy" "infra_policy" {
  arn = "arn:aws:iam::${var.aws_account["${var.infra_environment}"]}:policy/cloudinfr-base" # development or prod account owner id
}

resource "aws_iam_role_policy_attachment" "always_attach_cloudinfr_base" {
  role       = "${aws_iam_role.infra_role.name}"
  policy_arn = "${data.aws_iam_policy.infra_policy.arn}"
}

# Please do not remove the below resource block, this is still an issue as of 06/04/2020
# race condition on the aws side requires this ugly
# lookup otherwise instance profile is null and an invalid
# name error is thrown

resource "aws_iam_instance_profile" "infra_profile" {
  name  = "${var.project_name}-${var.project_environment}"
  role = "${aws_iam_role.infra_role.name}"
  provisioner "local-exec" {
     command = "echo ${aws_iam_instance_profile.infra_profile.arn}"
  }
}

resource "random_shuffle" "subnet_id" {
  input = "${var.subnet_id["${var.infra_environment}"]}"
  result_count = 1
}

# EC2 INSTANCES
resource "aws_instance" "infra_instance" {
  ami                     = "${data.aws_ami.core-cis-ubuntu.id}"
  instance_type           = var.instance_type
  subnet_id               = format("%s", "${random_shuffle.subnet_id.result[0]}") #subnet_id mappings for different vpc's based on account
  iam_instance_profile    = "${var.project_name}-${var.project_environment}"
  disable_api_termination = false # if you want protection change to true
  count                   = var.instance_count
  root_block_device {
    volume_size = var.root_volume_size
    volume_type = var.root_volume_type
    delete_on_termination = true
    encrypted = true
  }

  ebs_block_device {
    device_name = "/dev/sdb" # TODO: additional vols will have to rotate sdX based on count
    volume_type = var.additional_volume_type
    volume_size = var.additional_volume_size
  }
  
  # sg-046cda63 this is cloud-app in green(development)
  # sg-9c9711e4 this is cloud-app in red(production) there is another cloud-app sg outside of the vpc (maybe required in some cases)
  # sg-0f03d4be0197cca32 this is the medanalytics-sandbox secgroup generated by medistrano, may no longer be required
  # App secgroups currently in Medistrano have to be specified or imported

  vpc_security_group_ids = ["${var.infra_secgroup["${var.infra_environment}"]}", "sg-0f03d4be0197cca32", "${aws_security_group.infra_secgroup.id}"]

  tags = {
    Creator     = "medidata.cloudinfra"
    Company     = "medidata"
    CostCenter  = "platform"
    Ecosystem   = "Default"
    Environment = "${var.project_environment}"
    HostStage   = "non-prod"
    Name        = "${var.project_name}-${var.project_environment}-${var.project_type}"
    Product     = "${var.project_name}"
    Region      = "${var.region}"
    Tenant      = "medidata"
    Type        = "${var.project_type}"
    VPC         = "medistrano"
    herd_uuid   = "${var.project_name}-${var.project_environment}-${var.project_type}" # legacy?
    "mdsol:${var.project_name}:${var.project_environment}:corral:${var.project_type}" = "" # legacy tag
  }
}

# Route53 records and aliases
# Needs access to aws red account imedidata.net and imedidata.com zones live in that account
# You're thinking we should technically use a CNAME, agreed.
# Unfortunately AWS charges for CNAME queries, so we'll use an A record as an alias
# Quick Explanation about the records. Environments have been mapped based on domains
# For example *.imedidata.net is generally accepted as development and imedidata.com is production
# Of course, there are of many problems with mapping environment nomenclature to an actual domain
# Unfortunately split-horizon is currently not an option, current reason unknown, hopefully that changes.

resource "aws_route53_zone" "infra_dns" {
  name = "${var.infra_zone["${var.infra_environment}"]}" # imedidata.net or .com
}

resource "aws_route53_record" "infra_dns_record" {
  zone_id         = "${aws_route53_zone.infra_dns.zone_id}"
  name            = "${var.project_name}-${var.project_environment}.${var.infra_zone["${var.infra_environment}"]}"
  type            = "A"
  allow_overwrite = true # for now, this should be true as default

  alias {
    name                   = "${aws_elb.infra_load_balancer.dns_name}"
    zone_id                = "${aws_elb.infra_load_balancer.zone_id}"
    evaluate_target_health = true
  }
}