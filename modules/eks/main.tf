data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.eks_cluster_name
  kubernetes_version = "1.37"

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = { before_compute = true }
    vpc-cni                = { before_compute = true }
    aws-ebs-csi-driver = {
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
    metrics-server = {}
  }

  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  authentication_mode                      = "API"

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
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    },
    devops_access_entry_2 = {
      principal_arn = var.devops_user2_arn
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
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
# Pod Identity role assumed by the Karpenter pod
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.eks_cluster_name}-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnEquals = {
          "aws:SourceArn" = module.eks.cluster_arn
        }
      }
    }]
  })
}

resource "aws_eks_pod_identity_association" "karpenter_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}

# Node lifecycle policy, matching the Karpenter v1.15.0 official CloudFormation policy
resource "aws_iam_policy" "karpenter_node_lifecycle" {
  name = "KarpenterControllerNodeLifecyclePolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:capacity-reservation/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:placement-group/*"
        ]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                          = var.eks_cluster_name
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                          = var.eks_cluster_name
            "ec2:CreateAction"                                             = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          StringEqualsIfExists = {
            "aws:RequestTag/eks:eks-cluster-name" = var.eks_cluster_name
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      }
    ]
  })
}

# IAM integration, matching the Karpenter v1.15.0 official CloudFormation policy
resource "aws_iam_policy" "karpenter_iam_integration" {
  name = "KarpenterControllerIAMIntegrationPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Action   = ["iam:CreateInstanceProfile"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                          = var.eks_cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"                 = data.aws_region.current.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Action   = ["iam:TagInstanceProfile"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"                 = data.aws_region.current.region
            "aws:RequestTag/kubernetes.io/cluster/${var.eks_cluster_name}"  = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                           = var.eks_cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"                  = data.aws_region.current.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"                 = data.aws_region.current.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      }
    ]
  })
}

# EKS integration, matching the Karpenter v1.15.0 official CloudFormation policy
resource "aws_iam_policy" "karpenter_eks_integration" {
  name = "KarpenterControllerEKSIntegrationPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowAPIServerEndpointDiscovery"
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"
    }]
  })
}

# Resource discovery, matching the Karpenter v1.15.0 official CloudFormation policy
resource "aws_iam_policy" "karpenter_resource_discovery" {
  name = "KarpenterControllerResourceDiscoveryPolicy-${var.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribePlacementGroups",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.region
          }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}::parameter/aws/service/*"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
      {
        Sid      = "AllowUnscopedInstanceProfileListAction"
        Effect   = "Allow"
        Action   = "iam:ListInstanceProfiles"
        Resource = "*"
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = "iam:GetInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
      }
    ]
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
