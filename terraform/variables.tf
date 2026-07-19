variable "kubeconfig" {
  description = "Path to kubeconfig"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context of the k3d cluster"
  type        = string
  default     = "k3d-devops-task"
}

variable "repo_url" {
  description = "Git repository Argo CD syncs from"
  type        = string
  default     = "https://github.com/arevozyan-vention/test-repo.git"
}

variable "revision" {
  description = "Git revision to track"
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.1.4"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.5"
}
