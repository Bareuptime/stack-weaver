# Stack Weaver: Cluster.sh Installation Guide

This repository contains the `clustrize.sh` script for easy cluster setup and management.

## Download and Install

To download and install `clustrize.sh` on your system, run the following command in your terminal:

### Server Node Setup

**One-liner:**

```bash
export NETMAKER_TOKEN="<token>"
export ROLE=client
export NOMAD_SERVER_IP="<ip>"
export CONSUL_SERVER_IP="<ip>"
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh
```



```bash
sudo NETMAKER_TOKEN=<your-token> ROLE=server NOMAD_SERVER_IP=<server-ip> CONSUL_SERVER_IP=<consul-server-ip> bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```


**Multi-line (clearer input format):**

```bash
export NETMAKER_TOKEN=<your-token>
export ROLE=server
export NOMAD_SERVER_IP=<server-ip>
export CONSUL_SERVER_IP=<consul-server-ip>
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh

# sudo -E bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/main/clustrize.sh?$(date +%s))"
```

### Client Node Setup

**One-liner:**

```bash
sudo NETMAKER_TOKEN=<your-token> ROLE=client NOMAD_SERVER_IP=<server-ip> CONSUL_SERVER_IP=<consul-server-ip> bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```

**Multi-line (clearer input format):**

```bash
export NETMAKER_TOKEN=<your-token>
export ROLE=client
export NOMAD_SERVER_IP=<server-ip>
export CONSUL_SERVER_IP=<consul-server-ip>
wget -O clustrize.sh "https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s)" && sudo chmod +x clustrize.sh && sudo -E ./clustrize.sh

# sudo -E bash -c "$(wget -qO- https://raw.githubusercontent.com/Bareuptime/stack-weaver/refs/heads/main/clustrize.sh?$(date +%s))"
```

### Required Environment Variables

- `NETMAKER_TOKEN`: Your Netmaker enrollment token (mandatory)
- `ROLE`: Either `server` or `client`
- `NOMAD_SERVER_IP`: IP address of the server node
- `CONSUL_SERVER_IP`: IP address of the Consul server node

### Optional Environment Variables

- `NODE_NAME`: Custom node name (defaults to hostname)
- `DATACENTER`: Datacenter name (defaults to dc1)
- `ENCRYPT_KEY`: Consul encryption key (auto-generated if empty)
- `NETMAKER_ENDPOINT`: Netmaker server endpoint (auto-detected if empty)
- `STATIC_PORT`: Netmaker static port (defaults to 51821)

