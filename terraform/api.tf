resource "aws_launch_configuration" "api" {
  name_prefix                 = "${var.prefix}-nginx-"
  image_id                    = "${data.aws_ami.ubuntu.id}"
  instance_type               = "t2.micro"
  associate_public_ip_address = true

  security_groups = ["${aws_security_group.nginx.id}"]
  key_name        = "${aws_key_pair.demo.key_name}"
  user_data       = "${file("../scripts/api.sh")}"

  iam_instance_profile = "${aws_iam_instance_profile.consul.name}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "api" {
  name                 = "${var.prefix}-api-asg"
  launch_configuration = "${aws_launch_configuration.api.name}"
  desired_capacity     = 1
  min_size             = 1
  max_size             = 3
  vpc_zone_identifier  = ["${module.vpc.public_subnets[0]}"]

  lifecycle {
    create_before_destroy = true
  }

  tags = [
    {
      key                 = "Name"
      value               = "${var.prefix}-api"
      propagate_at_launch = true
    },
    {
      key                 = "Env"
      value               = "consul"
      propagate_at_launch = true
    },
  ]

}
