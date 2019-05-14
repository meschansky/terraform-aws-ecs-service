locals {
  docker_command_override = length(var.docker_command) > 0 ? "\"command\": [\"${var.docker_command}\"]," : ""
  enable_lb               = var.alb_enable_https || var.alb_enable_http ? true : false
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

resource "aws_ecs_service" "service_with_lb" {
  count                              = local.enable_lb ? 1 : 0
  name                               = "${var.service_identifier}-${var.task_identifier}-service"
  cluster                            = var.ecs_cluster_arn
  task_definition                    = aws_ecs_task_definition.task.arn
  desired_count                      = var.ecs_desired_count
  iam_role                           = aws_iam_role.service.arn
  deployment_maximum_percent         = var.ecs_deployment_maximum_percent
  deployment_minimum_healthy_percent = var.ecs_deployment_minimum_healthy_percent
  health_check_grace_period_seconds  = var.ecs_health_check_grace_period
  dynamic "ordered_placement_strategy" {
    for_each = var.ecs_placement_strategy
    content {
      # TF-UPGRADE-TODO: The automatic upgrade tool can't predict
      # which keys might be set in maps assigned here, so it has
      # produced a comprehensive set here. Consider simplifying
      # this after confirming which keys can be set in practice.

      field = lookup(ordered_placement_strategy.value, "field", null)
      type  = ordered_placement_strategy.value.type
    }
  }
  scheduling_strategy = var.ecs_scheduling_strategy

  load_balancer {
    target_group_arn = aws_alb_target_group.service[0].arn
    container_name   = "${var.service_identifier}-${var.task_identifier}"
    container_port   = var.app_port
  }

  depends_on = [
    aws_ecs_task_definition.task,
    aws_alb_target_group.service,
    aws_alb_listener.service_https,
    aws_alb_listener.service_http,
    aws_iam_role.service,
  ]
}

resource "aws_ecs_service" "service" {
  count           = local.enable_lb ? 0 : 1
  name            = "${var.service_identifier}-${var.task_identifier}-service"
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = var.ecs_desired_count

  #iam_role                           = "${aws_iam_role.service.arn}"
  deployment_maximum_percent         = var.ecs_deployment_maximum_percent
  deployment_minimum_healthy_percent = var.ecs_deployment_minimum_healthy_percent
  health_check_grace_period_seconds  = var.ecs_health_check_grace_period

  dynamic "ordered_placement_strategy" {
    for_each = var.ecs_placement_strategy
    content {
      # TF-UPGRADE-TODO: The automatic upgrade tool can't predict
      # which keys might be set in maps assigned here, so it has
      # produced a comprehensive set here. Consider simplifying
      # this after confirming which keys can be set in practice.

      field = lookup(ordered_placement_strategy.value, "field", null)
      type  = ordered_placement_strategy.value.type
    }
  }

  scheduling_strategy = var.ecs_scheduling_strategy

  depends_on = [
    aws_ecs_task_definition.task,
    aws_iam_role.service,
  ]
}

resource "aws_cloudwatch_log_group" "task" {
  name              = "${var.service_identifier}-${var.task_identifier}"
  retention_in_days = var.ecs_log_retention
}

