resource "azurerm_resource_group" "aks_resource_group" {
  location = "${var.location}"
  name     = "${var.cluster_name}-rg"
}

resource "azurerm_kubernetes_cluster" "aks_managed_cluster" {
  name                = "${var.cluster_name}"
  location            = "${azurerm_resource_group.aks_resource_group.location}"
  resource_group_name = "${azurerm_resource_group.aks_resource_group.name}"
  kubernetes_version  = "${var.k8s_version}"
  dns_prefix          = "${var.dns_prefix == "" ? var.cluster_name : var.dns_prefix}"

  agent_pool_profile {
    name            = "${var.agent_prefix}"
    vm_size         = "${var.agent_vm_sku}"
    count           = "${var.node_count}"
    os_type         = "Linux"
    os_disk_size_gb = "${var.node_os_disk_size_gb}"
    vnet_subnet_id  = "${var.subnet_id}"
  }

  linux_profile {
    admin_username = "${var.agent_admin_user}"

    ssh_key {
      key_data = "${var.public_key_data == "" ? file("~/.ssh/id_rsa.pub") : var.public_key_data}"
    }
  }

  service_principal {
    client_id     = "${var.sp_client_id}"
    client_secret = "${var.sp_client_secret}"
  }
}

resource "null_resource" "provision" {
  provisioner "local-exec" {
    command = "az aks get-credentials -n ${var.cluster_name} -g ${azurerm_resource_group.aks_resource_group.name}"
  }

  provisioner "local-exec" {
    command = "kubectl config use-context ${var.cluster_name}"
  }

  provisioner "local-exec" {
    # Create cluster role for tiller to work with multiple namespaces
    command = "kubectl apply -f ${replace(path.module, " ", "\\ ")}/k8s/tiller-rbac.yaml"
  }

  provisioner "local-exec" {
    # update helm
    command = "helm repo update && helm update"
  }

  provisioner "local-exec" {
    # install tiller and wait for the container to initialise on the cluster
    command = "helm init --service-account tiller && sleep 20 && kubectl cluster-info"
  }

  provisioner "local-exec" {
    # install ingress controller
    command = "helm install stable/nginx-ingress -n ${var.nginx_deployment_name} --namespace ${var.ingress_controller_namespace} --set controller.service.externalTrafficPolicy=Local --set controller.extraArgs.publish-service='${var.ingress_controller_namespace}/ingress-nginx-nginx-ingress-controller'"
  }

  # install cert-manager
  provisioner "local-exec" {
    command = "helm install stable/cert-manager -n ${var.cert_manager_deployment_name} --namespace ${var.ingress_controller_namespace}"
  }

  depends_on = ["azurerm_kubernetes_cluster.aks_managed_cluster"]
}

resource "null_resource" "connect_acr" {
  count = "${var.create_container_registry == "true" ? 1 : 0}"

  provisioner "local-exec" {
    command = "az role assignment create --assignee ${var.sp_client_id} --role Reader --scope ${module.container_registry.id}"
  }
}
