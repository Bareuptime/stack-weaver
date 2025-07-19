# Enhanced Bootstrap Script - Deployment Guide

## 🎯 Two Bootstrap Approaches

### **Approach 1: IP-Based Bootstrap (Recommended for Initial Setup)**
- Use hardcoded IPs for initial cluster bootstrap
- Solves chicken-and-egg problem
- Stable and tested approach

### **Approach 2: DNS-Based Service Discovery (For Scale)**
- Use Consul DNS for service discovery
- Automatic failover and load balancing
- Required for scaling beyond initial setup

---

## 🚀 Deployment Scenarios

### **Scenario 1: Fresh 3-Server Cluster (IP Bootstrap)**

**Step 1: Deploy First Server**
```bash
export ROLE=server
export BOOTSTRAP_PHASE=ip
export SERVER_COUNT=3
export NOMAD_SERVER_IP=10.10.85.1
export CONSUL_SERVER_IP=10.10.85.1
export VAULT_ADDR=https://10.10.85.1:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=server-1

./enhanced_bootstrap.sh
```

**Step 2: Deploy Second Server**
```bash
export ROLE=server
export BOOTSTRAP_PHASE=ip
export SERVER_COUNT=3
export NOMAD_SERVER_IP=10.10.85.1    # Point to first server
export CONSUL_SERVER_IP=10.10.85.1   # Point to first server
export VAULT_ADDR=https://10.10.85.1:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=server-2

./enhanced_bootstrap.sh
```

**Step 3: Deploy Third Server**
```bash
export ROLE=server
export BOOTSTRAP_PHASE=ip
export SERVER_COUNT=3
export NOMAD_SERVER_IP=10.10.85.1    # Point to first server
export CONSUL_SERVER_IP=10.10.85.1   # Point to first server
export VAULT_ADDR=https://10.10.85.1:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=server-3

./enhanced_bootstrap.sh
```

**Step 4: Deploy Clients (Can use DNS)**
```bash
export ROLE=client
export BOOTSTRAP_PHASE=dns           # Use service discovery
export VAULT_ADDR=https://vault.service.consul:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=client-1

./enhanced_bootstrap.sh
```

---

### **Scenario 2: Your Current Setup (Migrate Existing)**

**Current State:** VM1 (server), VM2 (client) with IP-based config

**Step 1: Fix VM2 (Your Current Issue)**
```bash
# On VM2 - Fix with IP bootstrap first
export ROLE=client
export BOOTSTRAP_PHASE=ip
export NOMAD_SERVER_IP=10.10.85.1
export CONSUL_SERVER_IP=10.10.85.1
export VAULT_ADDR=https://10.10.85.1:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=fastapi-server

./enhanced_bootstrap.sh
```

**Step 2: Add New Servers (IP Bootstrap)**
```bash
# VM3, VM4, VM5 as additional servers
export ROLE=server
export BOOTSTRAP_PHASE=ip
export SERVER_COUNT=3
export NOMAD_SERVER_IP=10.10.85.1
export CONSUL_SERVER_IP=10.10.85.1
# ... rest of config

./enhanced_bootstrap.sh
```

**Step 3: Migrate to DNS (Optional)**
```bash
# After all servers are running, migrate to DNS
./enhanced_bootstrap.sh migrate_to_dns
```

---

### **Scenario 3: DNS-First Approach (Advanced)**

**Prerequisites:**
- At least one server already running with Consul DNS
- Consul DNS accessible on port 53

**Deploy Any Node:**
```bash
export ROLE=client                   # or server
export BOOTSTRAP_PHASE=dns
export VAULT_ADDR=https://vault.service.consul:8200
export VAULT_TOKEN=your-vault-token
export NETMAKER_TOKEN=your-netmaker-token
export NODE_NAME=new-node

./enhanced_bootstrap.sh
```

---

## 🔧 Configuration Reference

### **Required Environment Variables**

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `ROLE` | Yes | Node role | `server` or `client` |
| `BOOTSTRAP_PHASE` | Yes | Bootstrap method | `ip` or `dns` |
| `VAULT_ADDR` | Yes | Vault server address | `https://10.10.85.1:8200` |
| `VAULT_TOKEN` | Yes | Vault auth token | `hvs.abc123...` |
| `NETMAKER_TOKEN` | Yes | Netmaker enrollment token | `token123` |
| `NODE_NAME` | No | Node identifier | `server-1` (defaults to hostname) |

### **IP Bootstrap Variables**

| Variable | Required for IP | Description | Example |
|----------|-----------------|-------------|---------|
| `NOMAD_SERVER_IP` | Yes | IP of Nomad server | `10.10.85.1` |
| `CONSUL_SERVER_IP` | Yes | IP of Consul server | `10.10.85.1` |
| `SERVER_COUNT` | Servers only | Expected server count | `3` |

---

## 🧪 Testing and Verification

### **Post-Deployment Checks**

**1. Check Service Status:**
```bash
sudo systemctl status vault-agent consul nomad
```

**2. Verify Certificates:**
```bash
sudo /usr/local/bin/monitor-certs.sh
sudo openssl x509 -in /etc/nomad.d/tls/nomad.pem -dates -noout
```

**3. Test DNS Resolution (DNS phase):**
```bash
dig @127.0.0.1 consul.service.consul
dig @127.0.0.1 nomad.service.consul
dig @127.0.0.1 vault.service.consul
```

**4. Check Cluster Membership:**
```bash
# Consul cluster
consul members

# Nomad cluster (with proper token)
export NOMAD_TOKEN=your-nomad-token
nomad server members
nomad node status
```

**5. Verify Service Discovery:**
```bash
# Check registered services
consul catalog services
consul catalog nodes -service nomad
```

---

## 🚨 Troubleshooting

### **Common Issues and Solutions**

**Issue: Certificate hostname errors**
```bash
# Check certificate SAN
openssl x509 -in /etc/nomad.d/tls/nomad.pem -text -noout | grep -A 10 "Subject Alternative Name"

# Should include: server.global.nomad, *.service.consul, etc.
```

**Issue: Services not starting**
```bash
# Check detailed logs
sudo journalctl -u vault-agent -n 50
sudo journalctl -u consul -n 50
sudo journalctl -u nomad -n 50
```

**Issue: DNS resolution not working**
```bash
# Check systemd-resolved config
sudo systemctl status systemd-resolved
sudo resolvectl status

# Test direct Consul DNS
dig @127.0.0.1 -p 53 consul.service.consul
```

**Issue: Vault Agent certificate failures**
```bash
# Check Vault connectivity
curl -sk $VAULT_ADDR/v1/sys/health

# Check token validity
vault auth -method=token token=$VAULT_TOKEN

# Check PKI role permissions
vault read pki-nodes/roles/node-cert
```

### **Recovery Procedures**

**Reset Node (Nuclear Option):**
```bash
sudo systemctl stop nomad consul vault-agent
sudo rm -rf /etc/consul.d/tls/* /etc/nomad.d/tls/*
sudo rm -rf /opt/consul/data/* /opt/nomad/data/*
# Re-run bootstrap script
```

**Certificate Emergency Refresh:**
```bash
sudo systemctl restart vault-agent
# Wait for certificate regeneration
sudo systemctl restart consul nomad
```

---

## 📊 Scaling Timeline

### **Your 8-Node Deployment Plan**

**Week 1: Fix Current Setup**
- Fix VM2 with IP bootstrap ✅
- Test certificate auto-renewal
- Verify basic functionality

**Week 2: Add First Server**
- Deploy VM3 as second server (IP bootstrap)
- Test HA failover
- Monitor cluster stability

**Week 3: Complete Server Cluster**
- Deploy VM4 as third server (IP bootstrap)
- Migrate clients to DNS discovery
- Deploy remaining clients (VM5-VM8)

**Final Architecture:**
```
Servers (IP bootstrap):     VM1, VM3, VM4
Clients (DNS discovery):    VM2, VM5, VM6, VM7, VM8
```

---

## 🔍 Key Benefits Achieved

### **IP Bootstrap Phase:**
✅ Solves chicken-and-egg problem  
✅ Stable, predictable deployment  
✅ Works with existing infrastructure  
✅ Easy troubleshooting  

### **DNS Discovery Phase:**
✅ Automatic service discovery  
✅ High availability and failover  
✅ Simplified client configuration  
✅ Scalable to 100+ nodes  

### **Hybrid Approach:**
✅ Best of both worlds  
✅ Production-ready security  
✅ Enterprise scalability  
✅ Operational simplicity  

---

## 🎯 Recommended Deployment Strategy

**For your immediate needs:**
1. Use **IP bootstrap** for all servers (VM1, VM3, VM4)
2. Use **DNS discovery** for all clients (VM2, VM5-VM8)
3. Migrate servers to DNS later (optional)

This approach gives you:
- ✅ **Immediate solution** to your current certificate issues
- ✅ **Stable foundation** for scaling to 8 nodes
- ✅ **Future flexibility** for further growth
- ✅ **Production readiness** with enterprise features