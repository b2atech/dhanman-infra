# Ansible

This directory contains Ansible playbooks and roles to automate server provisioning.

## Purpose
- Automate the transformation of a clean VPS into a production-ready server
- Ensure consistent server configuration across environments
- Enable rapid disaster recovery and failover

## Structure
```
ansible/
├── playbooks/          # Main playbooks for different provisioning tasks
├── roles/              # Reusable Ansible roles
├── inventory/          # Inventory files for different environments
├── group_vars/         # Group-level variables
├── host_vars/          # Host-specific variables
└── ansible.cfg         # Ansible configuration
```

## Usage
1. Configure inventory for your target servers
2. Update variables in group_vars or host_vars
3. Run playbooks: `ansible-playbook -i inventory/prod playbooks/site.yml`

## Getting Started
- Install Ansible: `pip install ansible`
- Set up SSH keys for target servers
- Customize inventory and variables for your environment
