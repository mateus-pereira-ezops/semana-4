resource "aws_ecr_repository" "repos" {
  for_each             = toset(var.repository_names)
  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  tags = {
    Project = var.project_name
  }
}
