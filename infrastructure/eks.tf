module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # EKS Auto Mode Configuration
  # Ye AWS ki taraf se fully managed node provisioning hai
  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Environment = "erp-platform"
  }
}
