resource "aws_iam_user" "devops_user1" {
  name = "devops_user1"
  path = "/devops/"
}

resource "aws_iam_user" "devops_user2" {
  name = "devops_user2"
  path = "/devops/"
}
