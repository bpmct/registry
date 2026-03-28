terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    incus = {
      source = "lxc/incus"
    }
  }
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

provider "incus" {}

# --------------------------------------------------------------------------- #
# Parameters
# --------------------------------------------------------------------------- #

data "coder_parameter" "image" {
  name         = "image"
  display_name = "OS Image"
  description  = "VM image to use. Must be available on the `images:` remote. ARM64 examples: `images:ubuntu/24.04`, `images:debian/12`."
  default      = "images:ubuntu/24.04"
  icon         = "/icon/image.svg"
  mutable      = false
  option {
    name  = "Ubuntu 24.04 LTS"
    value = "images:ubuntu/24.04"
  }
  option {
    name  = "Ubuntu 22.04 LTS"
    value = "images:ubuntu/22.04"
  }
  option {
    name  = "Debian 12"
    value = "images:debian/12"
  }
  option {
    name  = "Debian 11"
    value = "images:debian/11"
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU Cores"
  description  = "Number of vCPU cores to allocate to the VM."
  type         = "number"
  default      = "2"
  icon         = "https://raw.githubusercontent.com/matifali/logos/main/cpu-3.svg"
  mutable      = true
  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GB)"
  description  = "Amount of RAM to allocate to the VM in GB."
  type         = "number"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  validation {
    min = 1
    max = 16
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk Size (GB)"
  description  = "Root disk size in GB. Cannot be changed after workspace creation."
  type         = "number"
  default      = "20"
  icon         = "/icon/folder.svg"
  mutable      = false
  validation {
    min = 5
    max = 100
  }
}

data "coder_parameter" "git_repo" {
  type        = "string"
  name        = "git_repo"
  display_name = "Git Repository"
  default     = ""
  description = "(Optional) Clone a Git repo into the home directory on first start."
  mutable     = true
}

# --------------------------------------------------------------------------- #
# Locals
# --------------------------------------------------------------------------- #

locals {
  workspace_user    = lower(data.coder_workspace_owner.me.name)
  pool              = "coder"
  vm_name           = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
  agent_id          = data.coder_workspace.me.start_count == 1 ? coder_agent.main[0].id : ""
  agent_token       = data.coder_workspace.me.start_count == 1 ? coder_agent.main[0].token : ""
  agent_init_script = data.coder_workspace.me.start_count == 1 ? coder_agent.main[0].init_script : ""
}

# --------------------------------------------------------------------------- #
# Agent
# --------------------------------------------------------------------------- #

resource "coder_agent" "main" {
  count = data.coder_workspace.me.start_count
  arch  = data.coder_provisioner.me.arch
  os    = "linux"
  dir   = "/home/${local.workspace_user}"

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path /home/${local.workspace_user}"
    interval     = 60
    timeout      = 1
  }
}

# --------------------------------------------------------------------------- #
# Modules
# --------------------------------------------------------------------------- #

module "code-server" {
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.0"
  agent_id = local.agent_id
  folder   = "/home/${local.workspace_user}"
}

module "git-clone" {
  count    = data.coder_parameter.git_repo.value != "" ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = local.agent_id
  url      = data.coder_parameter.git_repo.value
  base_dir = "/home/${local.workspace_user}"
}

module "coder-login" {
  source   = "registry.coder.com/coder/coder-login/coder"
  version  = "~> 1.0"
  agent_id = local.agent_id
}

# --------------------------------------------------------------------------- #
# Storage volumes
# --------------------------------------------------------------------------- #

resource "incus_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  pool = local.pool
}

# --------------------------------------------------------------------------- #
# VM image
# --------------------------------------------------------------------------- #

resource "incus_cached_image" "image" {
  source_remote = split(":", data.coder_parameter.image.value)[0]
  source_image  = split(":", data.coder_parameter.image.value)[1]
}

# --------------------------------------------------------------------------- #
# Inject agent token into VM via a file before boot
# --------------------------------------------------------------------------- #

resource "incus_instance_file" "agent_token" {
  count              = data.coder_workspace.me.start_count
  instance           = incus_instance.dev.name
  content            = <<-EOF
    CODER_AGENT_TOKEN=${local.agent_token}
  EOF
  create_directories = true
  target_path        = "/opt/coder/init.env"
}

# --------------------------------------------------------------------------- #
# VM instance
# --------------------------------------------------------------------------- #

resource "incus_instance" "dev" {
  name    = local.vm_name
  image   = incus_cached_image.image.fingerprint
  running = data.coder_workspace.me.start_count == 1

  # Boot as a full VM (QEMU/KVM) instead of a container
  type = "virtual-machine"

  config = {
    "boot.autostart" = false

    "cloud-init.user-data" = <<-EOF
      #cloud-config
      hostname: ${lower(data.coder_workspace.me.name)}
      users:
        - name: ${local.workspace_user}
          uid: 1000
          gid: 1000
          groups: sudo
          shell: /bin/bash
          sudo: ['ALL=(ALL) NOPASSWD:ALL']
      packages:
        - curl
        - git
        - wget
        - vim
      write_files:
        - path: /opt/coder/init
          permissions: "0755"
          encoding: b64
          content: ${base64encode(local.agent_init_script)}
        - path: /etc/systemd/system/coder-agent.service
          permissions: "0644"
          content: |
            [Unit]
            Description=Coder Agent
            After=network-online.target
            Wants=network-online.target

            [Service]
            User=${local.workspace_user}
            EnvironmentFile=/opt/coder/init.env
            ExecStart=/opt/coder/init
            Restart=always
            RestartSec=10
            TimeoutStopSec=90
            KillMode=process
            OOMScoreAdjust=-900
            SyslogIdentifier=coder-agent

            [Install]
            WantedBy=multi-user.target
        - path: /etc/systemd/system/coder-agent-watcher.service
          permissions: "0644"
          content: |
            [Unit]
            Description=Coder Agent Token Watcher
            After=network-online.target

            [Service]
            Type=oneshot
            ExecStart=/usr/bin/systemctl restart coder-agent.service

            [Install]
            WantedBy=multi-user.target
        - path: /etc/systemd/system/coder-agent-watcher.path
          permissions: "0644"
          content: |
            [Path]
            PathModified=/opt/coder/init.env
            Unit=coder-agent-watcher.service

            [Install]
            WantedBy=multi-user.target
      runcmd:
        - chown -R ${local.workspace_user}:${local.workspace_user} /home/${local.workspace_user}
        - systemctl enable coder-agent.service coder-agent-watcher.service coder-agent-watcher.path
        - systemctl start coder-agent.service coder-agent-watcher.service coder-agent-watcher.path
    EOF
  }

  limits = {
    cpu    = tostring(data.coder_parameter.cpu.value)
    memory = "${data.coder_parameter.memory.value}GiB"
  }

  device {
    name = "home"
    type = "disk"
    properties = {
      path   = "/home/${local.workspace_user}"
      pool   = local.pool
      source = incus_volume.home.name
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = local.pool
      size = "${data.coder_parameter.disk_size.value}GiB"
    }
  }
}

# --------------------------------------------------------------------------- #
# Workspace metadata
# --------------------------------------------------------------------------- #

resource "coder_metadata" "info" {
  count       = data.coder_workspace.me.start_count
  resource_id = incus_instance.dev.name
  item {
    key   = "type"
    value = "VM (QEMU/KVM)"
  }
  item {
    key   = "image"
    value = data.coder_parameter.image.value
  }
  item {
    key   = "cpu"
    value = "${data.coder_parameter.cpu.value} cores"
  }
  item {
    key   = "memory"
    value = "${data.coder_parameter.memory.value} GB"
  }
  item {
    key   = "disk"
    value = "${data.coder_parameter.disk_size.value} GB"
  }
  item {
    key   = "fingerprint"
    value = substr(incus_cached_image.image.fingerprint, 0, 12)
  }
}
