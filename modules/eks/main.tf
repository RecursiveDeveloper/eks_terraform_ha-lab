data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name    = var.eks_cluster_name
  kubernetes_version = "1.33"

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = { before_compute = true }
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver     = {
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
    metrics-server         = {}
  }

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access = true
  authentication_mode = "API"

  vpc_id                   = var.vpc_id
  control_plane_subnet_ids = var.vpc_public_subnets
  subnet_ids               = var.vpc_private_subnets

  eks_managed_node_groups = var.eks_managed_node_groups

  tags = {
    "karpenter.sh/discovery" = var.eks_cluster_name
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.eks_cluster_name
  }

  # Node to node communication rule required by Karpenter-launched nodes
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  access_entries = {
    devops_access_entry_1 = {
      principal_arn = var.devops_user1_arn
      type          = "STANDARD"
    },
    devops_access_entry_2 = {
      principal_arn = var.devops_user2_arn
      type          = "STANDARD"
    }
  }
}

resource "aws_eks_access_policy_association" "devops_user1_policy_association" {
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = var.devops_user1_arn
  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_policy_association" "devops_user2_policy_association" {
  cluster_name  = module.eks.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = var.devops_user2_arn
  access_scope {
    type = "cluster"
  }
}

# ── EBS CSI Driver IRSA Role ───────────────────────────────────────────────────
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.eks_cluster_name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

# ── Karpenter Node Role ────────────────────────────────────────────────────────
# Role assumed by EC2 instances that Karpenter launches
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.eks_cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

# Instance profile so EC2 instances can assume the node role
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${var.eks_cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# Allow Karpenter nodes to connect to the cluster
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ── Karpenter Controller Role ──────────────────────────────────────────────────
# IRSA role assumed by the Karpenter pod
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.eks_cluster_name}-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Node lifecycle: launch, terminate, describe EC2 instances
resource "aws_iam_policy" "karpenter_node_lifecycle" {
  name = "KarpenterControllerNodeLifecyclePolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:launch-template/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:subnet/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:network-interface/*",
          "arn:aws:ec2:*::image/*",
          "arn:aws:ec2:*::snapshot/*"
        ]
      },
      {
        Sid    = "AllowScopedEC2TerminationActions"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowLaunchTemplateManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:launch-template/*"
      },
      {
        Sid    = "AllowInstanceTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["RunInstances", "CreateFleet"]
          }
        }
      }
    ]
  })
}

# IAM integration: pass the node role to EC2 instances
resource "aws_iam_policy" "karpenter_iam_integration" {
  name = "KarpenterControllerIAMIntegrationPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowPassNodeRole"
      Effect = "Allow"
      Action = "iam:PassRole"
      Resource = aws_iam_role.karpenter_node.arn
      Condition = {
        StringEquals = {
          "iam:PassedToService" = "ec2.amazonaws.com"
        }
      }
    }]
  })
}

# EKS integration: describe cluster and node groups
resource "aws_iam_policy" "karpenter_eks_integration" {
  name = "KarpenterControllerEKSIntegrationPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEKSDescribe"
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:DescribeNodegroup"
      ]
      Resource = "arn:aws:eks:*:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
    }]
  })
}

# Resource discovery: subnets, security groups, instance types, AMIs
resource "aws_iam_policy" "karpenter_resource_discovery" {
  name = "KarpenterControllerResourceDiscoveryPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowResourceDiscovery"
      Effect = "Allow"
      Action = [
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "pricing:GetProducts",
        "ssm:GetParameter"
      ]
      Resource = "*"
    }]
  })
}

# Attach all controller policies to the controller role
resource "aws_iam_role_policy_attachment" "karpenter_node_lifecycle" {
  policy_arn = aws_iam_policy.karpenter_node_lifecycle.arn
  role       = aws_iam_role.karpenter_controller.name
}

resource "aws_iam_role_policy_attachment" "karpenter_iam_integration" {
  policy_arn = aws_iam_policy.karpenter_iam_integration.arn
  role       = aws_iam_role.karpenter_controller.name
}

resource "aws_iam_role_policy_attachment" "karpenter_eks_integration" {
  policy_arn = aws_iam_policy.karpenter_eks_integration.arn
  role       = aws_iam_role.karpenter_controller.name
}

resource "aws_iam_role_policy_attachment" "karpenter_resource_discovery" {
  policy_arn = aws_iam_policy.karpenter_resource_discovery.arn
  role       = aws_iam_role.karpenter_controller.name
}
