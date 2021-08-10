#! /bin/sh
# DO NOT EDIT. Generated by terravalet.
# terravalet_output_format=2
#
# This script will move 3 items.

set -e

terraform state mv -lock=false -state=local.tfstate \
    'aws_batch_compute_environment.concourse_gpu_batch' \
    'module.ci.aws_batch_compute_environment.concourse_gpu_batch'

terraform state mv -lock=false -state=local.tfstate \
    'aws_instance.bar' \
    'module.ci.aws_instance.bar'

terraform state mv -lock=false -state=local.tfstate \
    'aws_instance.foo["cloud"]' \
    'module.ci.aws_instance.foo["cloud"]'

