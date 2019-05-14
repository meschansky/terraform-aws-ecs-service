locals {
  docker_command_override = length(var.docker_command) > 0 ? "\"command\": [\"${var.docker_command}\"]," : ""
  enable_lb               = var.alb_enable_https || var.alb_enable_http ? true : false
  service_registries      = var.create_service_registry ? [
    {
      registry_arn        = aws_service_discovery_service.this[0].arn
    }] : []
  load_balancer           = local.enable_lb ? [
    {
      target_group_arn = aws_alb_target_group.service[0].arn
      container_name   = "${var.service_identifier}-${var.task_identifier}"
      container_port   = var.app_port
    }
  ] : []
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  count       = var.create_service_registry ? 1 : 0
  name        = var.service_registry_namespace
  description = "DNS namespace"
  vpc         = "${var.vpc_id}"
}

resource "aws_service_discovery_service" "this" {
  count       = var.create_service_registry ? 1 : 0
  name = "this"

  dns_config {
    namespace_id = "${aws_service_discovery_private_dns_namespace.this[0].id}"

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 3
  }
}

data "template_file" "container_definition" {
  template = file("${path.module}/files/container_definition.json")

  vars = {
    service_identifier    = var.service_identifier
    task_identifier       = var.task_identifier
    image                 = var.docker_image
    memory                = var.docker_memory
    memory_reservation    = var.docker_memory_reservation
    app_port              = var.app_port
    command_override      = local.docker_command_override
    environment           = jsonencode(var.docker_environment)
    mount_points          = jsonencode(var.docker_mount_points)
    awslogs_group         = "${var.service_identifier}-${var.task_identifier}"
    awslogs_region        = data.aws_region.region.name
    awslogs_stream_prefix = var.service_identifier
  }
}

resource "null_resource" "show_task_definition_template" {
  triggers = {
    json = data.template_file.container_definition.rendered
  }
}

resource "aws_ecs_task_definition" "task" {
  family                = "${var.service_identifier}-${var.task_identifier}"
  container_definitions = data.template_file.container_definition.rendered
  network_mode          = var.network_mode
  task_role_arn         = aws_iam_role.task.arn
  placement_constraints {
    type       = "memberOf"
    expression = var.task_placement_constraints_expr
  }

  volume {
    name      = "data"
    host_path = var.ecs_data_volume_path
  }
}

resource "aws_ecs_service" "service" {
  name                               = "${var.service_identifier}-${var.task_identifier}-service"
  cluster                            = var.ecs_cluster_arn
  task_definition                    = aws_ecs_task_definition.task.arn
  desired_count                      = var.ecs_desired_count
  iam_role                           = local.enable_lb ? aws_iam_role.service.arn : null
  deployment_maximum_percent         = var.ecs_deployment_maximum_percent
  deployment_minimum_healthy_percent = var.ecs_deployment_minimum_healthy_percent
  health_check_grace_period_seconds  = var.ecs_health_check_grace_period
  dynamic "ordered_placement_strategy" {
    for_each = var.ecs_placement_strategy
    content {
      field = lookup(ordered_placement_strategy.value, "field", null)
      type  = ordered_placement_strategy.value.type
    }
  }
  scheduling_strategy = var.ecs_scheduling_strategy

  dynamic "load_balancer" {
    for_each = local.load_balancer
    content {
      target_group_arn = load_balancer.value.target_group_arn
      container_name   = load_balancer.value.container_name
      container_port   = load_balancer.value.container_port
    }
  }
  dynamic "service_registries" {
    for_each = local.service_registries
    content {
      registry_arn = service_registries.registry_arn
    }
  }
  depends_on = [
    aws_ecs_task_definition.task,
    aws_alb_target_group.service,
    aws_alb_listener.service_https,
    aws_alb_listener.service_http,
    aws_iam_role.service,
  ]
}


resource "aws_cloudwatch_log_group" "task" {
  name              = "${var.service_identifier}-${var.task_identifier}"
  retention_in_days = var.ecs_log_retention
}

