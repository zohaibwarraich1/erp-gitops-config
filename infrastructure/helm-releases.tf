# NGINX Ingress Controller
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.10.1"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Use AWS Network Load Balancer (NLB) instead of the deprecated Classic Load Balancer
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  # EKS Auto Mode (AWS Load Balancer Controller) defaults to internal NLB. 
  # We must explicitly request an internet-facing LB.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  depends_on = [module.eks]
}

# Cert-Manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.14.5"

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [module.eks]
}

# External Secrets Operator
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.9.20"

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Link the Helm Service Account to the AWS EKS IRSA Role
  # This provides the SA with permissions to read AWS Secrets Manager
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }

  depends_on = [module.eks, module.external_secrets_irsa]
}

# Monitoring Stack (Prometheus & Grafana)
resource "helm_release" "kube_prometheus_stack" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "58.1.3"

  # Fix: post-upgrade hooks (CRD update jobs) take long on EKS.
  # Increase timeout to 10 minutes and skip hook wait to avoid false failures.
  timeout          = 600
  atomic           = false
  cleanup_on_fail  = false

  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "400Mi"
  }

  # Disable admission webhooks to prevent TLS secret mount issues
  set {
    name  = "prometheusOperator.admissionWebhooks.enabled"
    value = "false"
  }

  set {
    name  = "prometheusOperator.tls.enabled"
    value = "false"
  }

  # Phase 4 – Allow Prometheus to discover PrometheusRules and ServiceMonitors
  # from all namespaces (not just the monitoring namespace)
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues"
    value = "false"
  }

  # Phase 4 – Enable Grafana sidecar to auto-load dashboards from ConfigMaps
  # Any ConfigMap with label grafana_dashboard=1 is auto-imported into Grafana
  set {
    name  = "grafana.sidecar.dashboards.enabled"
    value = "true"
  }

  set {
    name  = "grafana.sidecar.dashboards.label"
    value = "grafana_dashboard"
  }

  set {
    name  = "grafana.sidecar.dashboards.labelValue"
    value = "1"
  }

  # Search for dashboard ConfigMaps in ALL namespaces
  set {
    name  = "grafana.sidecar.dashboards.searchNamespace"
    value = "ALL"
  }

  # Configure Loki as a datasource for Grafana
  set {
    name  = "grafana.additionalDataSources[0].name"
    value = "Loki"
  }
  
  set {
    name  = "grafana.additionalDataSources[0].type"
    value = "loki"
  }
  
  set {
    name  = "grafana.additionalDataSources[0].url"
    value = "http://loki:3100"
  }
  
  set {
    name  = "grafana.additionalDataSources[0].access"
    value = "proxy"
  }

  depends_on = [module.eks]
}

# Phase 4 – Loki Stack (Log Aggregation)
# Deploys: Loki (log storage) + Promtail (log collector on every node)
# Promtail automatically collects logs from all pods in all namespaces
# Logs are visible in Grafana Explore → select Loki datasource
resource "helm_release" "loki_stack" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "2.10.2"

  # Enable Promtail to ship pod logs to Loki
  set {
    name  = "promtail.enabled"
    value = "true"
  }

  # Allow Promtail to schedule on nodes being disrupted by Karpenter
  set {
    name  = "promtail.tolerations[0].operator"
    value = "Exists"
  }

  # Disable Grafana in loki-stack (we already have it from kube-prometheus-stack)
  set {
    name  = "grafana.enabled"
    value = "false"
  }

  # Set Loki retention period to 30 days
  set {
    name  = "loki.config.chunk_store_config.max_look_back_period"
    value = "720h"
  }

  set {
    name  = "loki.config.table_manager.retention_deletes_enabled"
    value = "true"
  }

  set {
    name  = "loki.config.table_manager.retention_period"
    value = "720h"
  }

  # Resource limits for Loki
  set {
    name  = "loki.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "loki.resources.limits.memory"
    value = "512Mi"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ArgoCD (The GitOps Engine)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  # version          = "6.7.11"

  # Expose ArgoCD Server securely
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [module.eks]
}
