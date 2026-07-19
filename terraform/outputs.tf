output "argocd_ui" {
  value = "kubectl port-forward svc/argocd-server -n argocd 8090:80  ->  http://localhost:8090"
}

output "argocd_admin_password" {
  value = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
}
