data "aws_ami" "default" {
  most_recent = true

  filter {
    name   = "name"
    values = ["${var.operating_system.name}*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["${var.operating_system.owner}"]
}

module "machine_ports" {
  source = "../security"

  vpc_id           = var.vpc_id
  project_tag      = "machine_rules"
  cluster_name     = var.machine.name
  ports            = local.machine_ports
  tags             = var.tags
}

resource "aws_instance" "machine" {
  ami                    = data.aws_ami.default.id
  instance_type          = var.machine.spec.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = flatten([var.custom_security_group_ids, module.machine_ports.security_group_ids])

  dynamic "instance_market_options" {
    for_each = var.machine.spec.spot_max_price[*]
    content {
      market_type = "spot"
      dynamic "spot_options" {
        for_each = var.machine.spec.spot_max_price[*]
        content {
          instance_interruption_behavior = "hibernate"
          max_price = var.machine.spec.spot_max_price
          spot_instance_type = "persistent"
        }
      }
    }
  }

  root_block_device {
    delete_on_termination = "true"
    volume_size           = var.machine.spec.volume.size_gb
    volume_type           = var.machine.spec.volume.type
    iops                  = var.machine.spec.volume.type == "io2" ? var.machine.spec.volume.iops : var.machine.spec.volume.type == "io1" ? var.machine.spec.volume.iops : null
  }

  tags = var.tags

  lifecycle {
    # AMI is ignored because the data source
    # forces the resource to be re-created when apply is used again
    ignore_changes = [ami]
  }
}

resource "null_resource" "ensure_ssh_open" {
  count = local.additional_volumes_count
  triggers = {
    "depends_on" = can(module.machine_ports) ? local.additional_volumes_length : local.additional_volumes_length
  }

  provisioner "remote-exec" {
    inline = [
      "echo connected",
    ]
    connection {
      type        = "ssh"
      user        = var.operating_system.ssh_user
      host        = aws_instance.machine.public_ip
      port        = var.machine.spec.ssh_port
      agent       = var.use_agent # agent and private_key conflict
      private_key = var.use_agent ? null : var.ssh_priv_key
    }
  }
}

resource "aws_ebs_volume" "ebs_volume" {
  for_each = local.additional_volumes_map 

  availability_zone = var.az
  size              = each.value.size_gb
  type              = each.value.type
  iops              = each.value.type == "io2" ? each.value.iops : each.value.type == "io1" ? each.value.iops : null
  encrypted         = each.value.encrypted

  # Implicit dependency to aws_ebs_volume.ebs_volume
  tags = can(null_resource.ensure_ssh_open) ? var.tags : var.tags
}

resource "aws_volume_attachment" "attached_volume" {
  for_each = local.additional_volumes_map

  device_name = element(local.linux_device_names, tonumber(each.key))[0]
  volume_id   = aws_ebs_volume.ebs_volume[each.key].id
  instance_id = aws_instance.machine.id
  # Implicit dependency to aws_ebs_volume.ebs_volume
  stop_instance_before_detaching = can(aws_ebs_volume.ebs_volume) ? true : true
  lifecycle {
    ignore_changes = [volume_id]
  }
}

resource "null_resource" "copy_setup_volume_script" {
  count = local.additional_volumes_count
  triggers = {
    "depends_on" = local.additional_volumes_length
  }

  provisioner "file" {
    content     = file("${abspath(path.module)}/setup_volume.sh")
    destination = "/tmp/setup_volume.sh"

    connection {
      # Implicit dependency to null_resource.attached_volume
      type        = can(aws_volume_attachment.attached_volume) ? "ssh" : "ssh"
      user        = var.operating_system.ssh_user
      host        = aws_instance.machine.public_ip
      port        = var.machine.spec.ssh_port
      agent       = var.use_agent # agent and private_key conflict
      private_key = var.use_agent ? null : var.ssh_priv_key
    }
  }
}

resource "null_resource" "setup_volume" {
  for_each = local.additional_volumes_map
  provisioner "remote-exec" {
    inline = [
      "chmod a+x /tmp/setup_volume.sh",
      "/tmp/setup_volume.sh ${element(local.string_device_names, tonumber(each.key))} ${each.value.mount_point} ${length(lookup(var.machine.spec, "additional_volumes", [])) + 1} ${coalesce(each.value.filesystem, local.filesystem)} >> /tmp/mount.log 2>&1"
    ]

    connection {
      # Implicit dependency to null_resource.copy_setup_volume_script
      type        = can(null_resource.copy_setup_volume_script) ? "ssh" : "ssh"
      user        = var.operating_system.ssh_user
      host        = aws_instance.machine.public_ip
      port        = var.machine.spec.ssh_port
      agent       = var.use_agent # agent and private_key conflict
      private_key = var.use_agent ? null : var.ssh_priv_key
    }
  }
}
