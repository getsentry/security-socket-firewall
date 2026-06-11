# Security Socket Firewall

Terraform configuration for deploying [Socket Firewall](https://socket.dev) on a private GKE cluster in Google Cloud. The stack provisions networking, IAM, secrets, and a Helm release that proxies and scans package traffic to upstream registries (npm, PyPI, Maven).

Infrastructure code lives in [`terraform/`](terraform/).

## Architecture overview

The deployment runs Socket Firewall on a **private GKE cluster** with a **GKE Gateway** (internal by default), **Google-managed TLS** via Certificate Manager, **Cloud NAT** for outbound traffic, and **Secret Manager** for the Socket.dev API token.

```mermaid
flowchart TB
    subgraph TF["Terraform (state: GCS)"]
        TF_SA["Terraform SA<br/>socket-firewall-tf-apply@..."]
        GCS["GCS Backend<br/>sac-prod-tf--socket-firewall"]
    end

    subgraph GCP["GCP Project"]
        subgraph CM["Certificate Manager"]
            DNS_AUTH["DNS Authorization"]
            CERT["Managed Certificate"]
            CERT_MAP["Certificate Map"]
        end

        subgraph SM["Secret Manager"]
            API_SECRET["socket-firewall-api-token"]
        end

        subgraph VPC["VPC: socket-firewall-vpc"]
            subgraph SUBNET["Subnet: socket-firewall-subnet<br/>10.10.0.0/24"]
                subgraph GKE["GKE Private Cluster: socket-firewall"]
                    subgraph NS["Namespace: socket-firewall"]
                        GW["GKE Gateway<br/>gke-l7-rilb (internal)"]
                        ROUTE["HTTPRoute"]
                        HELM["Helm: socket-firewall<br/>chart v0.2.4"]
                        PODS["Firewall Pods<br/>replicas: 2, HTTP :80"]
                        K8S_SECRET["K8s Secret<br/>socket-api-token"]
                        SVC["Service: ClusterIP"]
                    end
                    NODES["Node Pool<br/>e2-standard-2, 1–3 nodes<br/>tag: gke-socket-firewall"]
                end
                NAT["Cloud Router + Cloud NAT"]
                FW_EGRESS["Firewall: allow egress<br/>TCP 80/443 → 0.0.0.0/0"]
            end
            CP["Private Control Plane<br/>172.16.0.0/28<br/>auth: IAP 35.235.240.0/20"]
        end

        NODE_SA["GKE Node SA<br/>logging + monitoring roles"]
    end

    subgraph EXTERNAL["External"]
        CLIENTS["Internal clients<br/>CI/CD, dev machines"]
        DNS["DNS provider"]
        REGISTRIES["Upstream registries<br/>npm / pypi / maven"]
        SOCKET_API["Socket.dev API"]
        ADMIN["Admin via IAP<br/>kubectl / helm"]
    end

    TF_SA --> GCS
    TF_SA --> GCP
    TF_SA --> API_SECRET
    TF_SA --> CM
    DNS_AUTH --> DNS
    CERT --> CERT_MAP
    CERT_MAP --> GW
    API_SECRET --> K8S_SECRET
    K8S_SECRET --> HELM
    HELM --> PODS
    PODS --> SVC
    GW --> ROUTE --> SVC
    NODES --> PODS
    NODE_SA --> NODES

    CLIENTS -->|"HTTPS (TLS at gateway)"| GW
    PODS -->|"scan packages"| SOCKET_API
    PODS -->|"proxy /npm, /pypi, /maven"| REGISTRIES
    NODES --> FW_EGRESS --> NAT --> REGISTRIES
    NODES --> NAT --> SOCKET_API
    ADMIN --> CP
```

## Network topology

```mermaid
flowchart LR
    subgraph VPC["socket-firewall-vpc"]
        subgraph SUB["socket-firewall-subnet (10.10.0.0/24)"]
            direction TB
            N1["GKE Nodes<br/>private IPs only"]
            GW_IP["GKE Gateway IP<br/>internal HTTPS LB"]
            SVC["ClusterIP Service<br/>socket-firewall :80"]
        end

        subgraph RANGES["Secondary IP ranges"]
            PODS["pods: 10.20.0.0/16"]
            SVC_CIDR["services: 10.30.0.0/16"]
        end

        ROUTER["Cloud Router"]
        NAT["Cloud NAT<br/>AUTO_ONLY"]
        MASTER["Control plane<br/>172.16.0.0/28<br/>private endpoint"]
    end

    INTERNET["Internet"]
    IAP["IAP TCP forwarding<br/>35.235.240.0/20"]
    CLIENT["VPC clients"]

    N1 --- PODS
    N1 --- SVC_CIDR
    N1 --> ROUTER --> NAT --> INTERNET
    CLIENT -->|"HTTPS :443"| GW_IP --> SVC --> N1
    IAP --> MASTER
    N1 -.->|"private nodes"| MASTER
```

## Data flow

```mermaid
sequenceDiagram
    participant Dev as Developer / CI
    participant GW as GKE Gateway
    participant FW as Socket Firewall Pod
    participant CM as Certificate Manager
    participant SM as Secret Manager
    participant Socket as Socket.dev API
    participant Reg as Upstream Registry

    Note over CM: DNS CNAME validates domain<br/>Google issues & renews cert
    Note over SM: API token stored out-of-band<br/>gcloud secrets versions add ...
    SM->>FW: K8s secret sync (Terraform)
    Dev->>GW: GET https://sfw.example.com/npm/...
    GW->>FW: HTTP to ClusterIP :80
    FW->>Socket: Security scan API
    FW->>Reg: Proxy package download
    Reg-->>FW: Package artifact
    FW-->>Dev: Scanned / allowed response
```

## Components

| Layer | Resource | Purpose |
|-------|----------|---------|
| **State** | GCS `sac-prod-tf--socket-firewall` | Remote Terraform state |
| **Network** | VPC + subnet + secondary ranges | Isolated network for GKE pods and services |
| **Egress** | Cloud NAT + egress firewall | Private nodes reach Socket.dev and registries (TCP 80/443) |
| **Compute** | Private GKE cluster + node pool | Runs Socket Firewall workloads |
| **Access** | IAP-authorized control plane | Only path to the private API server |
| **App** | Helm `socket-firewall` v0.2.4 | Package firewall with path-based routing |
| **Exposure** | GKE Gateway (GCP-managed TLS) or `LoadBalancer` Service | Internal gateway by default (`internal_load_balancer = true`) |
| **Secrets** | Secret Manager → K8s secret | `SOCKET_SECURITY_API_TOKEN` for Socket.dev |
| **TLS** | Certificate Manager + GKE Gateway | Google-managed cert for `firewall_domain`; HTTPS terminates at the load balancer |
| **IAM** | GKE node SA + Terraform SA | Least-privilege node ops; Terraform manages infrastructure |

## Path routing

When `firewall_domain` is set, the firewall exposes these upstream routes (defaults):

| Path | Upstream | Registry |
|------|----------|----------|
| `/npm` | `registry.npmjs.org` | npm |
| `/pypi` | `pypi.org` | pypi |
| `/maven` | `repo1.maven.org/maven2` | maven |

Health check endpoint: `https://<firewall_domain>/health`

## TLS

When `firewall_domain` is set and `enable_gcp_managed_tls = true` (default), Terraform provisions:

1. A **Certificate Manager DNS authorization** — publish the CNAME from `terraform output tls_dns_authorization_record`
2. A **Google-managed certificate** — becomes `ACTIVE` after DNS validation (typically 15–60 minutes)
3. A **GKE Gateway** with a **certificate map** — terminates HTTPS at the internal load balancer
4. An **HTTPRoute** — forwards decrypted traffic to the firewall pods on port 80

To use a pre-existing Kubernetes TLS secret instead (pod-level TLS with a `LoadBalancer` Service), set `enable_gcp_managed_tls = false` and `tls_existing_secret = "<secret-name>"`.

## Terraform layout

| File | Description |
|------|-------------|
| [`main.tf`](terraform/main.tf) | Providers, GCS backend, Kubernetes/Helm configuration |
| [`apis.tf`](terraform/apis.tf) | Required GCP API enablement |
| [`network.tf`](terraform/network.tf) | VPC, subnet, Cloud NAT, egress firewall |
| [`gke.tf`](terraform/gke.tf) | Private GKE cluster and node pool |
| [`iam.tf`](terraform/iam.tf) | GKE node SA and Terraform deployment SA roles |
| [`secrets.tf`](terraform/secrets.tf) | Secret Manager secret for the Socket API token |
| [`helm.tf`](terraform/helm.tf) | Namespace, K8s secret, Helm release |
| [`tls.tf`](terraform/tls.tf) | Certificate Manager cert, GKE Gateway, and HTTPRoute |
| [`variables.tf`](terraform/variables.tf) | Input variables |
| [`outputs.tf`](terraform/outputs.tf) | Cluster credentials, gateway IP, DNS auth record, health URL |
| [`terraform.tfvars.example`](terraform/terraform.tfvars.example) | Example configuration (copy to `terraform.tfvars`) |

## Getting started

1. Copy the example variables file and fill in your values:

   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

2. Bootstrap IAM for the Terraform service account (one-time, requires project Owner/Editor). See the comments in [`terraform/iam.tf`](terraform/iam.tf) for the full role list.

3. Initialise Terraform and create the Secret Manager secret container (the API value is loaded separately in step 4):

   ```bash
   cd terraform
   terraform init
   terraform apply -target=google_secret_manager_secret.socket_api_token
   ```

4. Load the Socket API token into the secret created in step 3:

   ```bash
   gcloud secrets versions add socket-firewall-api-token --data-file=- <<< "sktsec_..."
   ```

5. Apply the rest of the stack:

   ```bash
   terraform apply
   ```

6. If `firewall_domain` is set and `enable_gcp_managed_tls = true` (default), configure DNS:

   ```bash
   # Publish the CNAME for certificate validation
   terraform output tls_dns_authorization_record

   # After the certificate is ACTIVE (15–60 min), point the domain at the gateway IP
   terraform output firewall_load_balancer_ip
   ```

7. Configure `kubectl` using the output command:

   ```bash
   gcloud container clusters get-credentials socket-firewall --zone us-central1-a --project <project_id>
   ```